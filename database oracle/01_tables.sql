-- COUNTIES
CREATE TABLE Counties (
    CountyId NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    Name VARCHAR2(100) NOT NULL UNIQUE,
    Region VARCHAR2(80) NOT NULL,
    Headquarters VARCHAR2(80) NOT NULL,
    PopulationEstimate NUMBER NOT NULL,
    AreaSqKm NUMBER(10,1) NOT NULL,
    EcosystemFocus VARCHAR2(120) NOT NULL,
    RiskLevel VARCHAR2(20) NOT NULL,
    Overview VARCHAR2(500) NOT NULL,
    ContactPhone VARCHAR2(40) NOT NULL,
    ContactEmail VARCHAR2(120) NOT NULL
);

-- RESPONSE LOCATIONS
CREATE TABLE ResponseLocations (
    ResponseLocationId NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    LocationName VARCHAR2(140) NOT NULL,
    LocationType VARCHAR2(60) NOT NULL,
    CountyId NUMBER,
    Headquarters VARCHAR2(80) NOT NULL,
    FocusArea VARCHAR2(180) NOT NULL,
    ContactPhone VARCHAR2(40) NOT NULL,
    ContactEmail VARCHAR2(120) NOT NULL,
    CONSTRAINT fk_resp_county FOREIGN KEY (CountyId)
        REFERENCES Counties(CountyId)
);

-- SERVICES
CREATE TABLE Services (
    ServiceId NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    Title VARCHAR2(120) NOT NULL,
    Description VARCHAR2(280) NOT NULL,
    Controller VARCHAR2(60) NOT NULL,
    Action VARCHAR2(60) NOT NULL,
    SearchTerm VARCHAR2(100),
    SortOrder NUMBER NOT NULL
);

-- ADMIN USERS
CREATE TABLE AdminUsers (
    AdminUserId NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    FullName VARCHAR2(120) NOT NULL,
    Username VARCHAR2(60) NOT NULL UNIQUE,
    Email VARCHAR2(120) NOT NULL UNIQUE,
    PasswordHash VARCHAR2(255) NOT NULL,
    RoleName VARCHAR2(60) NOT NULL,
    IsActive NUMBER(1) DEFAULT 1 NOT NULL,
    LastLoginAt TIMESTAMP,
    CreatedAt TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL
);

-- ADMIN ACTIVITY LOG
CREATE TABLE AdminActivityLog (
    ActivityLogId NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    AdminUserId NUMBER NOT NULL,
    ActivityType VARCHAR2(80) NOT NULL,
    EntityType VARCHAR2(80) NOT NULL,
    EntityId NUMBER,
    Description VARCHAR2(320) NOT NULL,
    IpAddress VARCHAR2(64),
    OccurredAt TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT fk_admin_log FOREIGN KEY (AdminUserId)
        REFERENCES AdminUsers(AdminUserId)
);

-- LICENSING SERVICES
CREATE TABLE LicensingServices (
    LicenseServiceId NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    CountyId NUMBER,
    Title VARCHAR2(160) NOT NULL,
    Category VARCHAR2(80) NOT NULL,
    ProcessingWindowDays NUMBER NOT NULL,
    FeeKsh NUMBER(12,2) NOT NULL,
    AppliesTo VARCHAR2(180) NOT NULL,
    Summary VARCHAR2(450) NOT NULL,
    Requirements VARCHAR2(500) NOT NULL,
    IsFeatured NUMBER(1) DEFAULT 0 NOT NULL,
    SortOrder NUMBER NOT NULL,
    CONSTRAINT fk_license_county FOREIGN KEY (CountyId)
        REFERENCES Counties(CountyId)
);

-- UPDATES
CREATE TABLE Updates (
    UpdateId NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    CountyId NUMBER,
    Title VARCHAR2(180) NOT NULL,
    Summary VARCHAR2(400) NOT NULL,
    PublishDate DATE NOT NULL,
    Category VARCHAR2(60) NOT NULL,
    IsFeatured NUMBER(1) DEFAULT 0 NOT NULL,
    CONSTRAINT fk_updates_county FOREIGN KEY (CountyId)
        REFERENCES Counties(CountyId)
);

-- PROGRAMS
CREATE TABLE Programs (
    ProgramId NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    CountyId NUMBER NOT NULL,
    Title VARCHAR2(160) NOT NULL,
    Status VARCHAR2(30) NOT NULL,
    BudgetMillions NUMBER(10,1) NOT NULL,
    Beneficiaries NUMBER NOT NULL,
    Summary VARCHAR2(450) NOT NULL,
    CONSTRAINT fk_programs_county FOREIGN KEY (CountyId)
        REFERENCES Counties(CountyId)
);

-- RESEARCH ACTIVITIES
CREATE TABLE ResearchActivities (
    ResearchActivityId NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    CountyId NUMBER,
    Title VARCHAR2(180) NOT NULL,
    ResearchTheme VARCHAR2(90) NOT NULL,
    Status VARCHAR2(30) NOT NULL,
    LeadOffice VARCHAR2(140) NOT NULL,
    StartDate DATE NOT NULL,
    Summary VARCHAR2(450) NOT NULL,
    Outputs VARCHAR2(240) NOT NULL,
    IsFeatured NUMBER(1) DEFAULT 0 NOT NULL,
    CONSTRAINT fk_research_county FOREIGN KEY (CountyId)
        REFERENCES Counties(CountyId)
);

-- LICENSE APPLICATIONS
CREATE TABLE LicenseApplications (
    ApplicationId NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    LicenseServiceId NUMBER NOT NULL,
    ProjectCountyId NUMBER,
    ApplicantName VARCHAR2(120) NOT NULL,
    ApplicantEmail VARCHAR2(120) NOT NULL,
    OrganizationName VARCHAR2(160),
    ProjectLocation VARCHAR2(180) NOT NULL,
    ProjectSummary VARCHAR2(1200) NOT NULL,
    SupportingDocuments VARCHAR2(500) NOT NULL,
    Status VARCHAR2(30) NOT NULL,
    ReviewNotes VARCHAR2(500),
    ReviewedAt TIMESTAMP,
    SubmittedAt TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT fk_app_license FOREIGN KEY (LicenseServiceId)
        REFERENCES LicensingServices(LicenseServiceId),
    CONSTRAINT fk_app_county FOREIGN KEY (ProjectCountyId)
        REFERENCES Counties(CountyId)
);

-- INCIDENT REPORTS
CREATE TABLE IncidentReports (
    ReportId NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ReporterName VARCHAR2(80) NOT NULL,
    ReporterEmail VARCHAR2(120) NOT NULL,
    CountyId NUMBER,
    ResponseLocationId NUMBER NOT NULL,
    Category VARCHAR2(60) NOT NULL,
    Location VARCHAR2(120) NOT NULL,
    Description VARCHAR2(1200) NOT NULL,
    Status VARCHAR2(30) NOT NULL,
    ReviewNotes VARCHAR2(500),
    UpdatedAt TIMESTAMP,
    ReportedAt TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT fk_incident_county FOREIGN KEY (CountyId)
        REFERENCES Counties(CountyId),
    CONSTRAINT fk_incident_location FOREIGN KEY (ResponseLocationId)
        REFERENCES ResponseLocations(ResponseLocationId)
);

-- KNOWLEDGE DOCUMENTS
CREATE TABLE KnowledgeDocuments (
    DocumentId NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    SourceType VARCHAR2(60) NOT NULL,
    SourceRecordId NUMBER NOT NULL,
    CountyId NUMBER,
    Category VARCHAR2(90) NOT NULL,
    Title VARCHAR2(180) NOT NULL,
    Summary VARCHAR2(500) NOT NULL,
    RouteEndpoint VARCHAR2(60) NOT NULL,
    RouteRecordId NUMBER,
    NormalizedText VARCHAR2(2000) NOT NULL,
    TokenCount NUMBER NOT NULL,
    IndexedAt TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT uq_knowledge UNIQUE (SourceType, SourceRecordId),
    CONSTRAINT fk_knowledge_county FOREIGN KEY (CountyId)
        REFERENCES Counties(CountyId)
);

-- STOP WORDS
CREATE TABLE KnowledgeStopWords (
    Word VARCHAR2(40) PRIMARY KEY
);

-- VECTOR INDEX
CREATE TABLE KnowledgeVectorIndex (
    DocumentId NUMBER NOT NULL,
    DimensionNumber NUMBER NOT NULL,
    DimensionValue FLOAT NOT NULL,
    CONSTRAINT pk_vector PRIMARY KEY (DocumentId, DimensionNumber),
    CONSTRAINT fk_vector_doc FOREIGN KEY (DocumentId)
        REFERENCES KnowledgeDocuments(DocumentId)
);