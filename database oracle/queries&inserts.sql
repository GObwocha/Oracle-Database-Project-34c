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
-- ============================================================
-- 1. KnowledgeStopWords
-- ============================================================
INSERT ALL
  INTO KnowledgeStopWords (Word) VALUES ('a')
  INTO KnowledgeStopWords (Word) VALUES ('an')
  INTO KnowledgeStopWords (Word) VALUES ('and')
  INTO KnowledgeStopWords (Word) VALUES ('are')
  INTO KnowledgeStopWords (Word) VALUES ('as')
  INTO KnowledgeStopWords (Word) VALUES ('at')
  INTO KnowledgeStopWords (Word) VALUES ('be')
  INTO KnowledgeStopWords (Word) VALUES ('by')
  INTO KnowledgeStopWords (Word) VALUES ('for')
  INTO KnowledgeStopWords (Word) VALUES ('from')
  INTO KnowledgeStopWords (Word) VALUES ('has')
  INTO KnowledgeStopWords (Word) VALUES ('in')
  INTO KnowledgeStopWords (Word) VALUES ('is')
  INTO KnowledgeStopWords (Word) VALUES ('it')
  INTO KnowledgeStopWords (Word) VALUES ('of')
  INTO KnowledgeStopWords (Word) VALUES ('on')
  INTO KnowledgeStopWords (Word) VALUES ('or')
  INTO KnowledgeStopWords (Word) VALUES ('that')
  INTO KnowledgeStopWords (Word) VALUES ('the')
  INTO KnowledgeStopWords (Word) VALUES ('their')
  INTO KnowledgeStopWords (Word) VALUES ('this')
  INTO KnowledgeStopWords (Word) VALUES ('to')
  INTO KnowledgeStopWords (Word) VALUES ('with')
SELECT 1 FROM DUAL;

COMMIT;

-- ============================================================
-- 2. Counties
-- ============================================================
INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Mombasa', 'Coast', 'Mombasa', 1208333, 295.0, 'Coastal resilience and marine litter', 'High', 'Priority county for beach sanitation, storm surge resilience and marine litter enforcement around the port zone.', '+254 700 100 001', 'mombasa@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Kwale', 'Coast', 'Kwale', 866820, 8270.3, 'Coastal forests and quarry reclamation', 'Medium', 'Coordinates coastal forest protection, quarry-site rehabilitation and storm-water planning in growing towns.', '+254 700 100 002', 'kwale@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Kilifi', 'Coast', 'Kilifi', 1453787, 12917.5, 'Mangrove regeneration and beach cleanup', 'High', 'Coastal office handles mangrove restoration, marine debris action and tourism-zone shoreline cleanup.', '+254 700 100 003', 'kilifi@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Tana River', 'Coast Hinterland', 'Hola', 315943, 35375.8, 'Delta floodplains and riverine ecosystems', 'High', 'Leads floodplain management, delta ecosystem protection and seasonal river monitoring for vulnerable settlements.', '+254 700 100 004', 'tanariver@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Lamu', 'Coast', 'Lamu', 143920, 6273.1, 'Marine parks and mangrove protection', 'Medium', 'Combines heritage coast management, mangrove care and marine ecosystem monitoring across island and mainland wards.', '+254 700 100 005', 'lamu@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Taita Taveta', 'Coast Hinterland', 'Voi', 340671, 17084.1, 'Catchment rehabilitation and mining oversight', 'Medium', 'Works on catchment recovery, quarry and mining compliance, and wildlife-linked land stewardship.', '+254 700 100 006', 'taitataveta@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Garissa', 'North Eastern', 'Garissa', 835482, 44753.0, 'River Tana catchment and drought response', 'High', 'Coordinates flood preparedness along the Tana corridor while strengthening dryland vegetation recovery inland.', '+254 700 100 007', 'garissa@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Wajir', 'North Eastern', 'Wajir', 781263, 55840.0, 'Borehole governance and dryland recovery', 'High', 'Emphasis is on sustainable borehole use, range reseeding and emergency water-point coordination.', '+254 700 100 008', 'wajir@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Mandera', 'North Eastern', 'Mandera', 867457, 25798.3, 'Cross-border dryland water security', 'High', 'County teams focus on strategic water points, rangeland restoration and drought planning near border settlements.', '+254 700 100 009', 'mandera@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Marsabit', 'Northern Frontier', 'Marsabit', 459785, 66923.0, 'Dryland ecosystems and solid waste', 'Medium', 'County teams combine urban waste management with fragile ecosystem planning across vast arid landscapes.', '+254 700 100 010', 'marsabit@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Isiolo', 'Northern Frontier', 'Isiolo', 268002, 25336.1, 'Watershed management and grazing plans', 'Medium', 'Local office focuses on water points, grazing coordination and erosion control in transport-corridor settlements.', '+254 700 100 011', 'isiolo@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Meru', 'Eastern Highlands', 'Meru', 1545714, 7006.0, 'Highlands soil conservation', 'Medium', 'Runs hillside erosion control and upper catchment protection programs serving tea, coffee and mixed-farming areas.', '+254 700 100 012', 'meru@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Tharaka-Nithi', 'Eastern Highlands', 'Kathwana', 393177, 2564.0, 'Upper catchment farming and forest edges', 'Medium', 'Protects hill catchments, hillside farms and riparian corridors linking upland and lower semi-arid zones.', '+254 700 100 013', 'tharakanithi@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Embu', 'Eastern Highlands', 'Embu', 608599, 2818.0, 'Water tower protection and agroforestry', 'Medium', 'Supports agroforestry, spring protection and compliance monitoring around important water-source landscapes.', '+254 700 100 014', 'embu@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Kitui', 'Lower Eastern', 'Kitui', 1136187, 30496.5, 'Sand dams and semi-arid land restoration', 'Medium', 'Coordinates sand-dam protection, semi-arid land restoration and settlement water planning across large dry zones.', '+254 700 100 015', 'kitui@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Machakos', 'Lower Eastern', 'Machakos', 1421932, 5952.9, 'Sand harvesting control and water pans', 'Medium', 'County office is expanding watershed protection alongside community water pan rehabilitation and quarry oversight.', '+254 700 100 016', 'machakos@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Makueni', 'Lower Eastern', 'Wote', 987653, 8008.9, 'Dryland farming catchments and river protection', 'Medium', 'Builds riverbank protection, water harvesting and low-rainfall land restoration into county service planning.', '+254 700 100 017', 'makueni@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Nyandarua', 'Central', 'Ol Kalou', 638289, 3245.0, 'Moorland water sources and erosion control', 'Medium', 'Protects upper water sources, moorland catchments and hillside soils that feed major downstream rivers.', '+254 700 100 018', 'nyandarua@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Nyeri', 'Central', 'Nyeri', 759164, 3337.1, 'Aberdare catchment protection', 'Medium', 'Focused on forest catchments, clean water sources and land rehabilitation in upper watershed communities.', '+254 700 100 019', 'nyeri@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Kirinyaga', 'Central', 'Kerugoya', 610411, 1478.1, 'Irrigation efficiency and riverbank protection', 'Medium', 'Coordinates irrigation water use, riparian reserve enforcement and smallholder soil conservation in rice-growing zones.', '+254 700 100 020', 'kirinyaga@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Murang''a', 'Central', 'Murang''a', 1056640, 2325.8, 'Upper Tana catchment and solid waste', 'High', 'Combines catchment protection, market-waste controls and river source monitoring for fast-growing towns.', '+254 700 100 021', 'muranga@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Kiambu', 'Central', 'Kiambu', 2417735, 2538.0, 'River rehabilitation and peri-urban waste', 'High', 'Works on riverbank restoration, wastewater compliance and fast-growing peri-urban solid-waste systems.', '+254 700 100 022', 'kiambu@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Turkana', 'North Rift', 'Lodwar', 926976, 68180.0, 'Climate resilience and aquifer protection', 'High', 'Large dryland county prioritizing aquifer governance, solar water systems and drought early-warning coverage.', '+254 700 100 023', 'turkana@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('West Pokot', 'North Rift', 'Kapenguria', 621241, 9169.4, 'Hillside restoration and water harvesting', 'Medium', 'County teams support slope stabilization, range recovery and water harvesting in both hills and dry valley zones.', '+254 700 100 024', 'westpokot@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Samburu', 'North Rift', 'Maralal', 310327, 20182.5, 'Rangeland recovery and watershed care', 'Medium', 'Focuses on grazing-land balance, dry-season water security and land-restoration support for pastoral communities.', '+254 700 100 025', 'samburu@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Trans Nzoia', 'North Rift', 'Kitale', 990341, 2469.9, 'Slope stabilization and urban drainage', 'Medium', 'Combines agricultural-runoff controls with drainage improvement in market towns and hillside wards.', '+254 700 100 026', 'transnzoia@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Uasin Gishu', 'North Rift', 'Eldoret', 1163186, 3345.2, 'Urban drainage and agricultural runoff', 'Medium', 'County team manages drainage modernization while reducing runoff and waste pressure from agricultural zones.', '+254 700 100 027', 'uasingishu@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Elgeyo-Marakwet', 'North Rift', 'Iten', 454480, 3029.8, 'Escarpment restoration and spring protection', 'Medium', 'Protects escarpment slopes, spring recharge zones and settlement drainage in highland communities.', '+254 700 100 028', 'elgeyomarakwet@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Nandi', 'North Rift', 'Kapsabet', 885711, 2884.5, 'Watershed farming and river source protection', 'Medium', 'Links tea-growing catchments, river source protection and local waste compliance across high-rainfall wards.', '+254 700 100 029', 'nandi@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Baringo', 'North Rift', 'Kabarnet', 666763, 11015.3, 'Land restoration and water security', 'High', 'County operations target degraded landscapes, water harvesting and settlement resilience in flood-prone valleys.', '+254 700 100 030', 'baringo@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Laikipia', 'Central Rift', 'Rumuruti', 518560, 8696.1, 'Wildlife corridors and drought planning', 'Medium', 'Brings together ranching, wildlife conservancies and county officers on land restoration and drought plans.', '+254 700 100 031', 'laikipia@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Nakuru', 'Rift Valley', 'Nakuru', 2162202, 7509.0, 'Forest recovery and landfill control', 'High', 'Balances urban growth with forest restoration, dumpsite regulation and lake-basin land-use controls.', '+254 700 100 032', 'nakuru@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Narok', 'South Rift', 'Narok', 1157873, 17921.2, 'Mau forest restoration', 'High', 'Concentrates on forest-edge restoration, grassland recovery and tourism-area waste management.', '+254 700 100 033', 'narok@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Kajiado', 'Southern', 'Kajiado', 1117840, 21871.0, 'Rangeland conservation and human-wildlife balance', 'High', 'Prioritizes grazing-land recovery, wildlife corridor protection and drought-sensitive planning near Amboseli ecosystems.', '+254 700 100 034', 'kajiado@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Kericho', 'South Rift', 'Kericho', 901777, 2454.5, 'Tea catchment protection and waste control', 'Medium', 'Protects tea-growing catchments, town drainage and waste controls in fast-growing roadside markets.', '+254 700 100 035', 'kericho@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Bomet', 'South Rift', 'Bomet', 875689, 2037.4, 'Upper Mara catchments and waste management', 'Medium', 'Supports river source protection, farm-runoff reduction and solid-waste systems in upland towns.', '+254 700 100 036', 'bomet@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Kakamega', 'Western', 'Kakamega', 1867579, 3033.8, 'Rainforest conservation and river health', 'Medium', 'Protects forest fragments, urban drainage and river quality while coordinating market-waste interventions.', '+254 700 100 037', 'kakamega@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Vihiga', 'Western', 'Mbale', 590013, 531.0, 'Hillside drainage and market sanitation', 'Medium', 'County staff address steep-slope drainage, market sanitation and stream-bank encroachment in dense settlements.', '+254 700 100 038', 'vihiga@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Bungoma', 'Western', 'Bungoma', 1670570, 3023.9, 'Slope stabilization and market waste', 'Medium', 'Runs hillside rehabilitation, drainage works and town-market waste management upgrades.', '+254 700 100 039', 'bungoma@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Busia', 'Western', 'Busia', 893681, 1628.4, 'Border waste management and wetland care', 'Medium', 'County strategy centers on border-town waste systems, wetland protection and public sanitation improvements.', '+254 700 100 040', 'busia@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Siaya', 'Lake Basin', 'Siaya', 993183, 2496.1, 'Lake basin sanitation', 'Medium', 'Improves shoreline sanitation, fish-landing waste control and small-town water quality monitoring.', '+254 700 100 041', 'siaya@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Kisumu', 'Lake Basin', 'Kisumu', 1155574, 2085.9, 'Lake restoration and wetland protection', 'High', 'Coordinates wetland mapping, shoreline sanitation and fisheries catchment protection around Lake Victoria.', '+254 700 100 042', 'kisumu@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Homa Bay', 'Lake Basin', 'Homa Bay', 1131950, 3154.7, 'Shoreline sanitation and fish landing waste', 'Medium', 'County operations improve landing-site sanitation, bay cleanups and wetland protection around lake-edge communities.', '+254 700 100 043', 'homabay@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Migori', 'Lake Basin', 'Migori', 1116436, 2586.4, 'River catchments and small-scale mining control', 'Medium', 'Combines river source care, drainage monitoring and mining-site rehabilitation in mixed rural and town settings.', '+254 700 100 044', 'migori@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Kisii', 'Lake Basin', 'Kisii', 1266860, 1317.5, 'Hill slope drainage and urban waste', 'Medium', 'Protects steep urban catchments, drainage channels and river quality in dense highland settlements.', '+254 700 100 045', 'kisii@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Nyamira', 'Lake Basin', 'Nyamira', 605576, 899.4, 'Tea-zone river protection and drainage', 'Medium', 'Focuses on hill catchments, town drainage and stream-bank protection in tea and banana zones.', '+254 700 100 046', 'nyamira@kecsa.go.ke');

INSERT INTO Counties (Name, Region, Headquarters, PopulationEstimate, AreaSqKm, EcosystemFocus, RiskLevel, Overview, ContactPhone, ContactEmail)
VALUES ('Nairobi City', 'Central Metro', 'Nairobi', 4397073, 696.1, 'Urban drainage and air quality', 'High', 'Focuses on river cleanup, air quality monitoring and storm-water management around dense urban neighborhoods.', '+254 700 100 047', 'nairobi@kecsa.go.ke');

COMMIT;

-- ============================================================
-- 3. ResponseLocations  (from Counties)
-- ============================================================
INSERT INTO ResponseLocations
(
    LocationName,
    LocationType,
    CountyId,
    Headquarters,
    FocusArea,
    ContactPhone,
    ContactEmail
)
SELECT
    c.Name || ' County Environment Office',
    'County Office',
    c.CountyId,
    c.Headquarters,
    c.EcosystemFocus,
    c.ContactPhone,
    c.ContactEmail
FROM Counties c;

-- ============================================================
-- 4. ResponseLocations  (National)
-- ============================================================
INSERT INTO ResponseLocations
(
    LocationName,
    LocationType,
    CountyId,
    Headquarters,
    FocusArea,
    ContactPhone,
    ContactEmail
)
VALUES
('National Disaster Coordination Centre', 'National Coordination', NULL, 'Nairobi', 'Inter-county disaster alerts, flood response and emergency coordination', '+254 800 111 999', 'disasterdesk@kecsa.go.ke');

COMMIT;

-- ============================================================
-- 5. Services
-- ============================================================
INSERT INTO Services (Title, Description, Controller, Action, SearchTerm, SortOrder)
VALUES ('Browse county offices', 'View all 47 counties, their ecosystem focus areas and county office profiles.', 'Counties', 'Index', NULL, 1);

INSERT INTO Services (Title, Description, Controller, Action, SearchTerm, SortOrder)
VALUES ('Check licensing services', 'Review environmental permits, requirements, fees and processing windows.', 'Licensing', 'Index', NULL, 2);

INSERT INTO Services (Title, Description, Controller, Action, SearchTerm, SortOrder)
VALUES ('Apply for a licence', 'Submit an online licensing request for review by the relevant office.', 'LicenseApplications', 'Create', NULL, 3);

INSERT INTO Services (Title, Description, Controller, Action, SearchTerm, SortOrder)
VALUES ('Explore research activities', 'View field studies, monitoring work and county-linked environmental investigations.', 'Research', 'Index', NULL, 4);

INSERT INTO Services (Title, Description, Controller, Action, SearchTerm, SortOrder)
VALUES ('Search records and guidance', 'Search published county records, licensing information, research activity and notices.', 'KnowledgeSearch', 'Index', NULL, 5);

INSERT INTO Services (Title, Description, Controller, Action, SearchTerm, SortOrder)
VALUES ('Report an incident', 'Submit a pollution, flood or disaster report for review by the responsible office.', 'IncidentDesk', 'Index', NULL, 6);

INSERT INTO Services (Title, Description, Controller, Action, SearchTerm, SortOrder)
VALUES ('National disaster coordination desk', 'Use the national disaster coordination location for cross-county emergencies and public alerts.', 'IncidentDesk', 'Index', NULL, 7);

INSERT INTO Services (Title, Description, Controller, Action, SearchTerm, SortOrder)
VALUES ('Using this portal', 'Find service information, county contacts, applications and records from one public portal.', 'Home', 'Database', NULL, 8);

INSERT INTO Services (Title, Description, Controller, Action, SearchTerm, SortOrder)
VALUES ('Find coast counties', 'Jump straight to counties with coastal resilience and marine management programs.', 'Counties', 'Index', 'coast', 9);

INSERT INTO Services (Title, Description, Controller, Action, SearchTerm, SortOrder)
VALUES ('Check northern drought areas', 'Filter counties that are commonly associated with dryland planning and water security.', 'Counties', 'Index', 'north', 10);

INSERT INTO Services (Title, Description, Controller, Action, SearchTerm, SortOrder)
VALUES ('Explore forest counties', 'Search counties where watershed or forest rehabilitation is a major priority.', 'Counties', 'Index', 'forest', 11);

COMMIT;

-- ============================================================
-- 6. AdminUsers
-- ============================================================
INSERT INTO AdminUsers
(
    FullName,
    Username,
    Email,
    PasswordHash,
    RoleName,
    IsActive
)
VALUES
(
    'System Administrator',
    'admin',
    'admin@kecsa.go.ke',
    'scrypt:32768:8:1$cQvOZxDqWqlnfVcR$e15db87f4bd26c4d1bc627c57468e63147ce3a1e7f384745cdf62181625c840c84f1dabbe42b45fb49674a231deb4826f269509ae8c402e8c8def4f8a54bb469',
    'Super Administrator',
    1
);

COMMIT;

-- ============================================================
-- 7. LicensingServices
-- ============================================================
INSERT INTO LicensingServices (CountyId, Title, Category, ProcessingWindowDays, FeeKsh, AppliesTo, Summary, Requirements, IsFeatured, SortOrder)
VALUES (NULL, 'Environmental impact assessment licence', 'Impact assessment', 30, 25000, 'Large infrastructure, industrial, road and quarry projects', 'Used for projects that require structured environmental review before implementation.', 'Application form, project brief, site coordinates and proponent identification.', 1, 1);

INSERT INTO LicensingServices (CountyId, Title, Category, ProcessingWindowDays, FeeKsh, AppliesTo, Summary, Requirements, IsFeatured, SortOrder)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Nairobi City'), 'Air emissions operating permit', 'Air quality compliance', 21, 18500, 'Factories, boilers, generators and high-emission facilities', 'Supports county and national review of controlled emissions from urban and industrial sites.', 'Emission control plan, equipment inventory and latest compliance inspection notes.', 1, 2);

INSERT INTO LicensingServices (CountyId, Title, Category, ProcessingWindowDays, FeeKsh, AppliesTo, Summary, Requirements, IsFeatured, SortOrder)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Kisumu'), 'Wetland activity permit', 'Wetland protection', 18, 12000, 'Landing sites, shoreline works and wetland-adjacent community projects', 'Controls activity near wetlands to protect buffers, drainage and ecological function.', 'Site sketch, wetland buffer statement and community endorsement letter.', 1, 3);

INSERT INTO LicensingServices (CountyId, Title, Category, ProcessingWindowDays, FeeKsh, AppliesTo, Summary, Requirements, IsFeatured, SortOrder)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Mombasa'), 'Coastal event and beach use permit', 'Coastal management', 14, 9000, 'Large public events, temporary beach structures and shoreline activations', 'Helps coastal offices regulate public use of sensitive shoreline and marine-adjacent spaces.', 'Event schedule, sanitation plan and waste collection arrangement.', 1, 4);

INSERT INTO LicensingServices (CountyId, Title, Category, ProcessingWindowDays, FeeKsh, AppliesTo, Summary, Requirements, IsFeatured, SortOrder)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Taita Taveta'), 'Quarry rehabilitation compliance review', 'Extraction compliance', 24, 16000, 'Quarries, mining support yards and restoration contractors', 'Checks rehabilitation plans for extraction sites and nearby riverbank recovery commitments.', 'Site rehabilitation plan, extraction map and restoration timeline.', 0, 5);

INSERT INTO LicensingServices (CountyId, Title, Category, ProcessingWindowDays, FeeKsh, AppliesTo, Summary, Requirements, IsFeatured, SortOrder)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Machakos'), 'Sand harvesting environmental approval', 'River resource management', 16, 11000, 'Sand harvesting groups and riverbed extraction operators', 'Screens riverbed extraction activity and transport staging areas against catchment protection rules.', 'Sand harvesting plan, extraction route and community oversight committee details.', 0, 6);

INSERT INTO LicensingServices (CountyId, Title, Category, ProcessingWindowDays, FeeKsh, AppliesTo, Summary, Requirements, IsFeatured, SortOrder)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Turkana'), 'Borehole environmental screening permit', 'Water resource screening', 20, 14500, 'Public boreholes, strategic water points and solar pumping sites', 'Ensures new or upgraded boreholes account for environmental risk, waste handling and recharge protection.', 'Hydrogeology note, borehole coordinates and waste management plan.', 0, 7);

INSERT INTO LicensingServices (CountyId, Title, Category, ProcessingWindowDays, FeeKsh, AppliesTo, Summary, Requirements, IsFeatured, SortOrder)
VALUES (NULL, 'Community tree nursery registration', 'Ecosystem restoration', 10, 3000, 'Schools, youth groups and registered community organizations', 'Registers tree nursery operators supporting county restoration campaigns and school greening projects.', 'Registration certificate, site contact and seedling management plan.', 0, 8);

COMMIT;

-- ============================================================
-- 8. ResearchActivities
-- ============================================================
INSERT INTO ResearchActivities (CountyId, Title, ResearchTheme, Status, LeadOffice, StartDate, Summary, Outputs, IsFeatured)
VALUES (NULL, 'National environmental data observatory baseline', 'Data systems', 'Active', 'National Planning and Analytics Unit', DATE '2026-03-01', 'Builds a baseline dataset combining county environmental indicators, incident trends and permit activity for agency planning.', 'Baseline dashboard and county indicator matrix', 1);

INSERT INTO ResearchActivities (CountyId, Title, ResearchTheme, Status, LeadOffice, StartDate, Summary, Outputs, IsFeatured)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Nairobi City'), 'Nairobi industrial river discharge audit', 'Water quality', 'Field analysis', 'Nairobi City water quality laboratory', DATE '2026-03-18', 'Inspectors and lab teams are mapping discharge points and sampling river segments affected by industrial runoff.', 'Sampling log and discharge hotspot map', 1);

INSERT INTO ResearchActivities (CountyId, Title, ResearchTheme, Status, LeadOffice, StartDate, Summary, Outputs, IsFeatured)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Kilifi'), 'Mangrove regeneration survival study', 'Coastal ecosystems', 'Active', 'Kilifi coastal restoration desk', DATE '2026-03-14', 'Tracks seedling survival, tidal disturbance and community stewardship outcomes across restoration plots.', 'Survival scorecards and nursery lessons report', 1);

INSERT INTO ResearchActivities (CountyId, Title, ResearchTheme, Status, LeadOffice, StartDate, Summary, Outputs, IsFeatured)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Narok'), 'Mau forest edge soil loss survey', 'Catchment restoration', 'Active', 'Narok forest recovery unit', DATE '2026-03-10', 'Field teams are measuring slope erosion and land-use pressure in settlements along sensitive forest-edge zones.', 'Erosion transects and village risk profile', 1);

INSERT INTO ResearchActivities (CountyId, Title, ResearchTheme, Status, LeadOffice, StartDate, Summary, Outputs, IsFeatured)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Turkana'), 'Dryland borehole resilience mapping', 'Drought resilience', 'Monitoring', 'Turkana dryland planning office', DATE '2026-03-08', 'County teams are comparing borehole downtime, water demand and maintenance patterns in priority dry-season corridors.', 'Water-point uptime map and vulnerability brief', 0);

INSERT INTO ResearchActivities (CountyId, Title, ResearchTheme, Status, LeadOffice, StartDate, Summary, Outputs, IsFeatured)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Kisumu'), 'Lake Victoria shoreline wetland survey', 'Wetland monitoring', 'Published', 'Kisumu wetland and shoreline unit', DATE '2026-03-04', 'Shoreline teams completed wetland mapping and sanitation observations around major landing and settlement areas.', 'Wetland atlas summary and sanitation gap list', 0);

INSERT INTO ResearchActivities (CountyId, Title, ResearchTheme, Status, LeadOffice, StartDate, Summary, Outputs, IsFeatured)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Tana River'), 'Tana delta floodplain habitat mapping', 'Floodplain ecology', 'Active', 'Tana River ecosystem office', DATE '2026-02-26', 'Combines flood history, settlement exposure and habitat condition data to support floodplain protection planning.', 'Floodplain habitat map and settlement exposure notes', 0);

INSERT INTO ResearchActivities (CountyId, Title, ResearchTheme, Status, LeadOffice, StartDate, Summary, Outputs, IsFeatured)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Kakamega'), 'Kakamega school biodiversity field study', 'Forest biodiversity', 'Scheduled', 'Kakamega county education and forest liaison desk', DATE '2026-04-03', 'School clubs and county officers will conduct guided biodiversity observations in buffer sites linked to restoration work.', 'Field workbook and school biodiversity checklist', 0);

COMMIT;

-- ============================================================
-- 9. Updates
-- ============================================================
INSERT INTO Updates (CountyId, Title, Summary, PublishDate, Category, IsFeatured)
VALUES (NULL, 'National disaster coordination centre activates flood and drought watch desk', 'County officers have been asked to feed incident data to the national coordination desk for cross-county flood and drought monitoring.', DATE '2026-03-26', 'Alert', 1);

INSERT INTO Updates (CountyId, Title, Summary, PublishDate, Category, IsFeatured)
VALUES (NULL, 'National drought readiness bulletin released for county planners', 'County officers have been asked to review water storage, borehole governance and dry-season response plans before the next quarter.', DATE '2026-03-24', 'Guidance', 1);

INSERT INTO Updates (CountyId, Title, Summary, PublishDate, Category, IsFeatured)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Nairobi City'), 'Nairobi River cleanup phase one begins in industrial sections', 'Joint teams are piloting litter traps, water sampling and enforcement patrols along priority river segments.', DATE '2026-03-22', 'Press release', 1);

INSERT INTO Updates (CountyId, Title, Summary, PublishDate, Category, IsFeatured)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Kilifi'), 'Kilifi school partnership expands mangrove seedling nurseries', 'Environmental clubs and ward offices are scaling up community mangrove nurseries ahead of the long-rains planting window.', DATE '2026-03-20', 'News', 0);

INSERT INTO Updates (CountyId, Title, Summary, PublishDate, Category, IsFeatured)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Turkana'), 'Turkana approves phase two of solar borehole rehabilitation', 'County planners extended the rehabilitation package to additional dry-season access points.', DATE '2026-03-18', 'Project update', 0);

INSERT INTO Updates (CountyId, Title, Summary, PublishDate, Category, IsFeatured)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Kakamega'), 'Kakamega forest buffer survey opens for public participation', 'Communities bordering key forest sections have been invited to verify mapping outputs and local restoration priorities.', DATE '2026-03-16', 'Consultation', 0);

INSERT INTO Updates (CountyId, Title, Summary, PublishDate, Category, IsFeatured)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Mombasa'), 'Mombasa marine litter taskforce launches beach and harbor cleanout', 'County and port partners will track marine litter hotspots and intensify shoreline cleanup days.', DATE '2026-03-14', 'Press release', 0);

INSERT INTO Updates (CountyId, Title, Summary, PublishDate, Category, IsFeatured)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Narok'), 'Narok expands ranger-supported restoration around Mau fringe villages', 'Community groups will receive seedlings, fencing support and monitoring tools in sensitive catchment areas.', DATE '2026-03-11', 'News', 0);

INSERT INTO Updates (CountyId, Title, Summary, PublishDate, Category, IsFeatured)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Kisumu'), 'Kisumu publishes wetland mapping summary for priority landing sites', 'The new summary identifies shoreline sanitation gaps and areas needing buffer restoration.', DATE '2026-03-09', 'Research', 0);

INSERT INTO Updates (CountyId, Title, Summary, PublishDate, Category, IsFeatured)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Homa Bay'), 'Homa Bay expands fish-landing sanitation support', 'County officers will roll out new waste sorting and shoreline cleanup routines at selected landing sites.', DATE '2026-03-08', 'Project update', 0);

COMMIT;

-- ============================================================
-- 10. Programs
-- ============================================================
INSERT INTO Programs (CountyId, Title, Status, BudgetMillions, Beneficiaries, Summary)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Nairobi City'), 'Urban River Recovery Corridors', 'Active', 148.5, 235000, 'Combines riverbank cleanup, storm-water interceptors and neighborhood awareness campaigns in dense settlement areas.');

INSERT INTO Programs (CountyId, Title, Status, BudgetMillions, Beneficiaries, Summary)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Mombasa'), 'Coastal Solid Waste Interception Network', 'Active', 96.0, 180000, 'Expands litter interception, segregation points and marine debris monitoring around beaches and the port.');

INSERT INTO Programs (CountyId, Title, Status, BudgetMillions, Beneficiaries, Summary)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Kisumu'), 'Lake Edge Wetland Restoration', 'Active', 84.2, 142000, 'Protects papyrus wetlands, landing sites and shoreline sanitation zones around peri-urban settlements.');

INSERT INTO Programs (CountyId, Title, Status, BudgetMillions, Beneficiaries, Summary)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Nakuru'), 'Menengai Catchment and Dumpsite Upgrade', 'Planned', 121.0, 210000, 'Links waste-cell upgrades with upper catchment restoration and drainage redesign in growth corridors.');

INSERT INTO Programs (CountyId, Title, Status, BudgetMillions, Beneficiaries, Summary)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Kiambu'), 'Peri-Urban Waste Compliance Drive', 'Active', 77.4, 165000, 'Improves waste transfer controls, riparian monitoring and sewer overflow response in satellite towns.');

INSERT INTO Programs (CountyId, Title, Status, BudgetMillions, Beneficiaries, Summary)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Kajiado'), 'Amboseli Rangeland Water Balance Program', 'Active', 111.8, 98000, 'Coordinates water points, grazing plans and ecosystem monitoring for wildlife-compatible dryland management.');

INSERT INTO Programs (CountyId, Title, Status, BudgetMillions, Beneficiaries, Summary)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Narok'), 'Mau Forest Community Restoration Blocks', 'Active', 102.3, 86000, 'Funds seedlings, boundary support and community restoration teams across the forest fringe.');

INSERT INTO Programs (CountyId, Title, Status, BudgetMillions, Beneficiaries, Summary)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Turkana'), 'Solar Borehole Reliability Upgrade', 'Active', 134.6, 124000, 'Improves solar pumping systems, source protection and telemetry at strategic water points.');

INSERT INTO Programs (CountyId, Title, Status, BudgetMillions, Beneficiaries, Summary)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Kakamega'), 'Rainforest Buffer Livelihood Program', 'Planned', 69.5, 54000, 'Pairs forest-edge agroforestry with drainage controls and household tree planting.');

INSERT INTO Programs (CountyId, Title, Status, BudgetMillions, Beneficiaries, Summary)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Kilifi'), 'Mangrove and Beach Stewardship Scheme', 'Active', 88.1, 73000, 'Community groups manage mangrove nurseries, shoreline cleanup and erosion watch activities.');

INSERT INTO Programs (CountyId, Title, Status, BudgetMillions, Beneficiaries, Summary)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Taita Taveta'), 'Quarry Compliance and Riverbank Recovery', 'Monitoring', 45.0, 31000, 'Inspects extraction sites while restoring adjacent riverbanks and access roads.');

INSERT INTO Programs (CountyId, Title, Status, BudgetMillions, Beneficiaries, Summary)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Uasin Gishu'), 'Urban Drainage and Farm Runoff Shield', 'Planned', 72.2, 91000, 'Improves storm-water channels and demonstration runoff-control plots near growth centers.');

INSERT INTO Programs (CountyId, Title, Status, BudgetMillions, Beneficiaries, Summary)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Homa Bay'), 'Lake Shore Waste Transfer Improvement', 'Active', 54.3, 47000, 'Builds waste transfer points and shoreline collection systems around busy lake landing areas.');

INSERT INTO Programs (CountyId, Title, Status, BudgetMillions, Beneficiaries, Summary)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Kericho'), 'Tea Catchment Springs Protection Program', 'Planned', 41.8, 38000, 'Protects spring heads, tea-zone drains and small river source points serving rural communities.');

INSERT INTO Programs (CountyId, Title, Status, BudgetMillions, Beneficiaries, Summary)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Mandera'), 'Dryland Water Access Resilience Scheme', 'Active', 118.7, 82000, 'Strengthens emergency water points, catchment fencing and public reporting for drought-sensitive settlements.');

INSERT INTO Programs (CountyId, Title, Status, BudgetMillions, Beneficiaries, Summary)
VALUES ((SELECT CountyId FROM Counties WHERE Name = 'Vihiga'), 'Town Drainage and Market Sanitation Upgrade', 'Monitoring', 28.4, 26000, 'Improves drainage chokepoints and sanitation routines in densely settled market centers.');

COMMIT;

-- ============================================================
-- 11. LicenseApplications
-- ============================================================
INSERT INTO LicenseApplications
(
    LicenseServiceId,
    ProjectCountyId,
    ApplicantName,
    ApplicantEmail,
    OrganizationName,
    ProjectLocation,
    ProjectSummary,
    SupportingDocuments,
    Status,
    SubmittedAt
)
VALUES
(
    (SELECT LicenseServiceId FROM LicensingServices WHERE Title = 'Environmental impact assessment licence'),
    (SELECT CountyId FROM Counties WHERE Name = 'Nairobi City'),
    'Grace Njeri',
    'grace.njeri@example.com',
    'CityGreen Infrastructure Ltd',
    'Industrial Area, Nairobi',
    'Application for environmental review of a medium-scale recycling and materials recovery site planned near existing industrial utilities.',
    'Project brief, site map, company certificate and sanitation concept note',
    'Submitted',
    SYSTIMESTAMP - INTERVAL '3' DAY
);

INSERT INTO LicenseApplications
(
    LicenseServiceId,
    ProjectCountyId,
    ApplicantName,
    ApplicantEmail,
    OrganizationName,
    ProjectLocation,
    ProjectSummary,
    SupportingDocuments,
    Status,
    SubmittedAt
)
VALUES
(
    (SELECT LicenseServiceId FROM LicensingServices WHERE Title = 'Wetland activity permit'),
    (SELECT CountyId FROM Counties WHERE Name = 'Kisumu'),
    'Brian Odhiambo',
    'brian.odhiambo@example.com',
    'Lakefront Community Initiative',
    'Dunga shoreline, Kisumu',
    'Community group seeking approval for a controlled boardwalk and cleanup staging zone near a sensitive wetland edge.',
    'Community endorsement letter, wetland buffer sketch and site photos',
    'Under review',
    SYSTIMESTAMP - INTERVAL '1' DAY
);

COMMIT;

-- ============================================================
-- 12. IncidentReports
-- ============================================================
INSERT INTO IncidentReports
(
    ReporterName,
    ReporterEmail,
    CountyId,
    ResponseLocationId,
    Category,
    Location,
    Description,
    Status,
    ReportedAt
)
VALUES
('Faith Mwangi', 'faith.mwangi@example.com',
 (SELECT CountyId FROM Counties WHERE Name = 'Nairobi City'),
 (SELECT ResponseLocationId FROM ResponseLocations WHERE LocationName = 'Nairobi City County Environment Office'),
 'Illegal dumping', 'Korogocho bridge', 'Unsorted waste has been dumped close to the riverbank for three days and is blocking storm-water flow.', 'Under review', SYSTIMESTAMP - INTERVAL '4' DAY);

INSERT INTO IncidentReports
(
    ReporterName,
    ReporterEmail,
    CountyId,
    ResponseLocationId,
    Category,
    Location,
    Description,
    Status,
    ReportedAt
)
VALUES
('Abdi Hassan', 'abdi.hassan@example.com',
 (SELECT CountyId FROM Counties WHERE Name = 'Garissa'),
 (SELECT ResponseLocationId FROM ResponseLocations WHERE LocationName = 'Garissa County Environment Office'),
 'Flood risk', 'Tana embankment section B', 'Erosion near the embankment has widened after recent rains and nearby farms are at risk if the bank fails.', 'New', SYSTIMESTAMP - INTERVAL '2' DAY);

INSERT INTO IncidentReports
(
    ReporterName,
    ReporterEmail,
    CountyId,
    ResponseLocationId,
    Category,
    Location,
    Description,
    Status,
    ReportedAt
)
VALUES
('Joy Achieng', 'joy.achieng@example.com',
 (SELECT CountyId FROM Counties WHERE Name = 'Kisumu'),
 (SELECT ResponseLocationId FROM ResponseLocations WHERE LocationName = 'Kisumu County Environment Office'),
 'Water contamination', 'Dunga landing site', 'Fish traders reported dirty discharge entering the lake edge and causing a strong smell in the morning.', 'Closed', SYSTIMESTAMP - INTERVAL '1' DAY);

INSERT INTO IncidentReports
(
    ReporterName,
    ReporterEmail,
    CountyId,
    ResponseLocationId,
    Category,
    Location,
    Description,
    Status,
    ReportedAt
)
VALUES
('Peter Wekesa', 'peter.wekesa@example.com',
 NULL,
 (SELECT ResponseLocationId FROM ResponseLocations WHERE LocationName = 'National Disaster Coordination Centre'),
 'Disaster response', 'National flood desk, Nairobi', 'Two counties reported flood displacement overnight and the national centre opened a cross-county coordination ticket for rapid response.', 'Escalated', SYSTIMESTAMP - INTERVAL '10' HOUR);

COMMIT;

-- ============================================================
-- 13. Rebuild knowledge index
-- ============================================================
BEGIN
    RebuildKnowledgeIndex;
END;
/