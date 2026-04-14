CREATE OR REPLACE FUNCTION NormalizeKnowledgeText (p_input IN NVARCHAR2)
RETURN NVARCHAR2
AS
    v_cleaned NVARCHAR2(32767);
    v_result NVARCHAR2(2000);
BEGIN
    v_cleaned := LOWER(NVL(p_input, ''));
    -- Replace punctuation and multiple spaces
    v_cleaned := REGEXP_REPLACE(v_cleaned, '[[:punct:]]', ' ');
    v_cleaned := REGEXP_REPLACE(v_cleaned, '\s+', ' ');
    v_cleaned := TRIM(v_cleaned);

    IF v_cleaned IS NULL OR v_cleaned = '' THEN
        RETURN '';
    END IF;

    SELECT LISTAGG(word, ' ') WITHIN GROUP (ORDER BY lvl) INTO v_result
    FROM (
        SELECT TRIM(REGEXP_SUBSTR(v_cleaned, '[^ ]+', 1, level)) AS word, level AS lvl
        FROM dual
        CONNECT BY level <= REGEXP_COUNT(v_cleaned, ' ') + 1
    )
    WHERE LENGTH(word) > 1 AND REGEXP_LIKE(word, '^[a-z0-9]+$')
    AND NOT EXISTS (SELECT 1 FROM KnowledgeStopWords WHERE Word = word);

    RETURN SUBSTR(NVL(v_result, ''), 1, 2000);
END;

CREATE OR REPLACE PROCEDURE RebuildKnowledgeIndex
AS
BEGIN

    DELETE FROM KnowledgeVectorIndex;
    DELETE FROM KnowledgeDocuments;

    INSERT INTO KnowledgeDocuments
    (
        SourceType,
        SourceRecordId,
        CountyId,
        Category,
        Title,
        Summary,
        RouteEndpoint,
        RouteRecordId,
        NormalizedText,
        TokenCount
    )
    WITH SourceRows AS
    (
        SELECT
            'County profile' AS SourceType,
            c.CountyId AS SourceRecordId,
            c.CountyId AS CountyId,
            'County directory' AS Category,
            c.Name || ' County profile' AS Title,
            c.Overview AS Summary,
            'county_details' AS RouteEndpoint,
            c.CountyId AS RouteRecordId,
            c.Name || ' county profile ' || c.Region || ' ' ||
            c.Headquarters || ' ' || c.EcosystemFocus || ' ' || c.Overview AS SearchText
        FROM Counties c

        UNION ALL

        SELECT
            'License service',
            ls.LicenseServiceId,
            ls.CountyId,
            ls.Category,
            ls.Title,
            ls.Summary,
            'licensing',
            NULL,
            ls.Title || ' ' || ls.Category || ' ' || NVL(c.Name, 'national') || ' ' ||
            ls.AppliesTo || ' ' || ls.Summary || ' ' || ls.Requirements
        FROM LicensingServices ls
        LEFT JOIN Counties c ON c.CountyId = ls.CountyId

        UNION ALL

        SELECT
            'Research activity',
            ra.ResearchActivityId,
            ra.CountyId,
            ra.ResearchTheme,
            ra.Title,
            ra.Summary,
            'research',
            NULL,
            ra.Title || ' ' || ra.ResearchTheme || ' ' || NVL(c.Name, 'national') || ' ' ||
            ra.LeadOffice || ' ' || ra.Status || ' ' || ra.Summary || ' ' || ra.Outputs
        FROM ResearchActivities ra
        LEFT JOIN Counties c ON c.CountyId = ra.CountyId

        UNION ALL

        SELECT
            'Program',
            p.ProgramId,
            p.CountyId,
            p.Status,
            p.Title,
            p.Summary,
            'county_details',
            p.CountyId,
            c.Name || ' ' || p.Title || ' ' || p.Status || ' ' ||
            p.Summary || ' budget ' || TO_CHAR(p.BudgetMillions) || ' beneficiaries ' ||
            TO_CHAR(p.Beneficiaries)
        FROM Programs p
        INNER JOIN Counties c ON c.CountyId = p.CountyId

        UNION ALL

        SELECT
            'Update',
            u.UpdateId,
            u.CountyId,
            u.Category,
            u.Title,
            u.Summary,
            'home',
            NULL,
            NVL(c.Name, 'National') || ' ' || u.Title || ' ' ||
            u.Category || ' ' || u.Summary
        FROM Updates u
        LEFT JOIN Counties c ON c.CountyId = u.CountyId
    ),
    NormalizedRows AS
    (
        SELECT
            sr.SourceType,
            sr.SourceRecordId,
            sr.CountyId,
            sr.Category,
            sr.Title,
            sr.Summary,
            sr.RouteEndpoint,
            sr.RouteRecordId,
            NormalizeKnowledgeText(sr.SearchText) AS NormalizedText
        FROM SourceRows sr
    )
    SELECT
        nr.SourceType,
        nr.SourceRecordId,
        nr.CountyId,
        nr.Category,
        nr.Title,
        nr.Summary,
        nr.RouteEndpoint,
        nr.RouteRecordId,
        nr.NormalizedText,
        CASE
            WHEN nr.NormalizedText = '' THEN 0
            ELSE LENGTH(nr.NormalizedText) - LENGTH(REPLACE(nr.NormalizedText, ' ', '')) + 1
        END AS TokenCount
    FROM NormalizedRows nr
    WHERE nr.NormalizedText <> '';

    INSERT INTO KnowledgeVectorIndex
    (
        DocumentId,
        DimensionNumber,
        DimensionValue
    )
    WITH TokenRows AS
    (
        SELECT
            kd.DocumentId,
            TRIM(REGEXP_SUBSTR(kd.NormalizedText, '[^ ]+', 1, level)) AS token
        FROM KnowledgeDocuments kd
        CONNECT BY level <= REGEXP_COUNT(kd.NormalizedText, ' ') + 1
        AND PRIOR kd.DocumentId = kd.DocumentId
        AND PRIOR SYS_GUID() IS NOT NULL
        AND LENGTH(TRIM(REGEXP_SUBSTR(kd.NormalizedText, '[^ ]+', 1, level))) > 1
    ),
    TokenCounts AS
    (
        SELECT
            DocumentId,
            token,
            COUNT(*) AS token_count
        FROM TokenRows
        GROUP BY DocumentId, token
    ),
    DimensionContributions AS
    (
        SELECT
            tc.DocumentId,
            MOD(ORA_HASH(tc.token || 'dim'), 48) + 1 AS DimensionNumber,
            (CASE WHEN MOD(ORA_HASH(tc.token || 'sign'), 2) = 0 THEN 1.0 ELSE -1.0 END) *
            ((1.0 + LN(tc.token_count)) *
            (1.0 + LEAST(LENGTH(tc.token), 12) / 12.0)) AS RawValue
        FROM TokenCounts tc
    ),
    DimensionSums AS
    (
        SELECT
            dc.DocumentId,
            dc.DimensionNumber,
            SUM(dc.RawValue) AS RawValue
        FROM DimensionContributions dc
        GROUP BY dc.DocumentId, dc.DimensionNumber
    ),
    Norms AS
    (
        SELECT
            ds.DocumentId,
            SQRT(SUM(ds.RawValue * ds.RawValue)) AS VectorNorm
        FROM DimensionSums ds
        GROUP BY ds.DocumentId
    )
    SELECT
        ds.DocumentId,
        ds.DimensionNumber,
        ds.RawValue / n.VectorNorm
    FROM DimensionSums ds
    INNER JOIN Norms n ON n.DocumentId = ds.DocumentId
    WHERE n.VectorNorm > 0 AND ABS(ds.RawValue) > 0.0000001;

    SELECT
        COUNT(*) AS document_count,
        (SELECT COUNT(*) FROM KnowledgeVectorIndex) AS index_row_count,
        MAX(IndexedAt) AS last_indexed_at
    FROM KnowledgeDocuments;
END;

CREATE OR REPLACE TRIGGER tr_AdminActivityLog
AFTER INSERT OR UPDATE OR DELETE ON Programs
FOR EACH ROW
DECLARE
    v_action NVARCHAR2(20);
    v_entity_id NUMBER;
BEGIN
    IF INSERTING THEN
        v_action := 'INSERT';
        v_entity_id := :NEW.ProgramId;
    ELSIF UPDATING THEN
        v_action := 'UPDATE';
        v_entity_id := :NEW.ProgramId;
    ELSIF DELETING THEN
        v_action := 'DELETE';
        v_entity_id := :OLD.ProgramId;
    END IF;

    INSERT INTO AdminActivityLog (AdminUserId, ActivityType, EntityType, EntityId)
    SELECT
        a.AdminUserId,
        v_action,
        'Programs',
        v_entity_id
    FROM AdminUsers a
    WHERE a.Username = USER;
END;
/

CREATE OR REPLACE TRIGGER tr_LicenseApplications
AFTER INSERT OR UPDATE OR DELETE ON LicenseApplications
FOR EACH ROW
DECLARE
    v_action NVARCHAR2(20);
    v_entity_id NUMBER;
BEGIN
    IF INSERTING THEN
        v_action := 'INSERT';
        v_entity_id := :NEW.ApplicationId;
    ELSIF UPDATING THEN
        v_action := 'UPDATE';
        v_entity_id := :NEW.ApplicationId;
    ELSIF DELETING THEN
        v_action := 'DELETE';
        v_entity_id := :OLD.ApplicationId;
    END IF;

    INSERT INTO AdminActivityLog (AdminUserId, ActivityType, EntityType, EntityId)
    SELECT
        a.AdminUserId,
        v_action,
        'LicenseApplications',
        v_entity_id
    FROM AdminUsers a
    WHERE a.Username = USER;
END;
/

-- Oracle Data Pump export command (run from command line):
-- expdp system/password schemas=nema_db directory=backup_dir dumpfile=backup.dmp logfile=backup.log

DECLARE
    v_base_folder VARCHAR2(500) := '/u01/app/oracle/backup/';
    v_backup_path VARCHAR2(500);
    v_file_name VARCHAR2(100) := 'KenyaEnvironmentPortal_DynamicBackup.dmp';
BEGIN
    -- Create directory if needed (requires DBA privileges)
    EXECUTE IMMEDIATE 'CREATE OR REPLACE DIRECTORY backup_dir AS ''' || v_base_folder || '''';
    v_backup_path := v_base_folder || v_file_name;
    -- Use Data Pump export
    DBMS_DATAPUMP.OPEN('EXPORT', 'SCHEMA', NULL, 'backup_job');
    DBMS_DATAPUMP.ADD_FILE('backup_job', v_file_name, 'BACKUP_DIR');
    DBMS_DATAPUMP.METADATA_FILTER('backup_job', 'SCHEMA_EXPR', 'IN (''NEMA_DB'')');
    DBMS_DATAPUMP.START_JOB('backup_job');
    DBMS_OUTPUT.PUT_LINE('Backup successfully created at: ' || v_backup_path);
END;
/
