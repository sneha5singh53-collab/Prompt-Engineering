-- TCL AI Demand Generation Engine — Central Data Model (Section 26)
-- Target: Postgres (recommended). Adjust types if deployed on Airtable/other via n8n abstraction layer.
-- Every entity carries created_at/updated_at/source for full audit trail (Section 27).

CREATE TABLE account (
    account_id              TEXT PRIMARY KEY,
    company_name            TEXT NOT NULL,
    domain                  TEXT,
    industry                TEXT,
    employee_count          INTEGER,
    geography               TEXT,
    icp_fit                 NUMERIC(5,2),
    vayu_fit                NUMERIC(5,2),
    cyber_fit               NUMERIC(5,2),
    cis_fit                 NUMERIC(5,2),
    vayu_opportunity_score  NUMERIC(5,2),
    cyber_opportunity_score NUMERIC(5,2),
    cis_opportunity_score   NUMERIC(5,2),
    primary_opportunity     TEXT CHECK (primary_opportunity IN ('VAYU','CYBER','CIS')),
    secondary_opportunity   TEXT CHECK (secondary_opportunity IN ('VAYU','CYBER','CIS')),
    intent_score            NUMERIC(5,2),
    engagement_score        NUMERIC(5,2),
    account_priority        TEXT CHECK (account_priority IN ('High','Medium','Low')),
    account_stage           TEXT, -- L1..L8 per Section 24
    active_campaign_lock    TEXT, -- campaign_id currently owning outreach, or NULL
    nurture_level           TEXT CHECK (nurture_level IN ('HOT','WARM','COLD_BUT_FIT', NULL)),
    next_best_action        TEXT, -- Section 17 enum, enforced at application layer
    sales_status             TEXT,
    last_activity_at        TIMESTAMPTZ,
    source                  TEXT DEFAULT 'account_import',
    created_at               TIMESTAMPTZ DEFAULT now(),
    updated_at               TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE contact (
    contact_id        TEXT PRIMARY KEY,
    account_id        TEXT REFERENCES account(account_id),
    full_name         TEXT,
    title             TEXT,
    persona_type      TEXT,
    email             TEXT,
    linkedin_url      TEXT,
    email_verified    BOOLEAN DEFAULT FALSE,
    is_primary_contact BOOLEAN DEFAULT FALSE,
    suppression_flag  BOOLEAN DEFAULT FALSE,
    created_at         TIMESTAMPTZ DEFAULT now(),
    updated_at         TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE product (
    product_id        TEXT PRIMARY KEY,
    product_name       TEXT NOT NULL,
    product_group      TEXT CHECK (product_group IN ('VAYU_CLOUD','CYBER_SECURITY','CIS_KALEYRA')),
    knowledge_base_ref TEXT -- path to config/products/*.json
);

CREATE TABLE campaign (
    campaign_id        TEXT PRIMARY KEY,
    campaign_code       TEXT UNIQUE, -- e.g. V1, C3, I7
    product_id          TEXT REFERENCES product(product_id),
    name                TEXT,
    status              TEXT CHECK (status IN ('draft','active','paused','archived')),
    lemlist_campaign_id TEXT,
    activation_rule     TEXT,
    is_active           BOOLEAN DEFAULT FALSE
);

CREATE TABLE signal (
    signal_id           TEXT PRIMARY KEY,
    account_id           TEXT REFERENCES account(account_id),
    product_id           TEXT REFERENCES product(product_id),
    signal_type          TEXT,
    signal_source         TEXT,
    signal_date           DATE,
    confidence            TEXT CHECK (confidence IN ('low','medium','high')),
    weight_applied        NUMERIC(5,2),
    decay_applied_score   NUMERIC(5,2),
    created_at             TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE intent (
    intent_id        TEXT PRIMARY KEY,
    account_id        TEXT REFERENCES account(account_id),
    product_id        TEXT REFERENCES product(product_id),
    intent_score       NUMERIC(5,2),
    computed_at         TIMESTAMPTZ DEFAULT now(),
    driving_signals     TEXT[] -- array of signal_id
);

CREATE TABLE activity (
    activity_id       TEXT PRIMARY KEY,
    account_id         TEXT REFERENCES account(account_id),
    contact_id         TEXT REFERENCES contact(contact_id),
    activity_type       TEXT,
    channel             TEXT,
    occurred_at          TIMESTAMPTZ,
    detail_ref           TEXT
);

CREATE TABLE outreach (
    outreach_id        TEXT PRIMARY KEY,
    account_id          TEXT REFERENCES account(account_id),
    contact_id          TEXT REFERENCES contact(contact_id),
    campaign_id          TEXT REFERENCES campaign(campaign_id),
    sequence_step         INTEGER,
    sent_at               TIMESTAMPTZ,
    message_variant        TEXT,
    status                 TEXT CHECK (status IN ('scheduled','sent','opened','clicked','replied','bounced','unsubscribed'))
);

CREATE TABLE response (
    response_id         TEXT PRIMARY KEY,
    outreach_id          TEXT REFERENCES outreach(outreach_id),
    response_type          TEXT,
    sentiment               TEXT,
    received_at              TIMESTAMPTZ,
    classified_as            TEXT, -- e.g. positive_business_reply, meeting_requested, not_now, wrong_person, auto_reply
    routed_action             TEXT
);

CREATE TABLE lead (
    lead_id             TEXT PRIMARY KEY,
    account_id           TEXT REFERENCES account(account_id),
    contact_id           TEXT REFERENCES contact(contact_id),
    product_id           TEXT REFERENCES product(product_id),
    qualified_at           TIMESTAMPTZ,
    qualification_reason    TEXT NOT NULL, -- never empty, per Section 13 rule 6
    status                   TEXT CHECK (status IN ('open','handed_off','closed_won','closed_lost'))
);

CREATE TABLE sales_handoff (
    handoff_id              TEXT PRIMARY KEY,
    lead_id                  TEXT REFERENCES lead(lead_id),
    brief_ref                 TEXT,
    sent_to_sales_at           TIMESTAMPTZ,
    sales_feedback              TEXT,
    feedback_classification      TEXT CHECK (feedback_classification IN
        ('qualified','not_qualified','wrong_persona','wrong_product','no_requirement',
         'timing_issue','existing_vendor','competitor','opportunity','lost')),
    feedback_at                  TIMESTAMPTZ
);

CREATE TABLE nurture (
    nurture_id            TEXT PRIMARY KEY,
    account_id              TEXT REFERENCES account(account_id),
    nurture_level             TEXT CHECK (nurture_level IN ('HOT','WARM','COLD_BUT_FIT')),
    entered_at                 TIMESTAMPTZ DEFAULT now(),
    reactivation_trigger        TEXT,
    reactivated_at                TIMESTAMPTZ
);

CREATE TABLE suppression (
    suppression_id      TEXT PRIMARY KEY,
    contact_id            TEXT REFERENCES contact(contact_id),
    account_id            TEXT REFERENCES account(account_id),
    reason                 TEXT,
    suppressed_at            TIMESTAMPTZ DEFAULT now(),
    scope                    TEXT CHECK (scope IN ('contact','account','global'))
);

-- Central activation queue (Section 25) — materialised daily by WF-07, not a base table
CREATE VIEW tcl_activation_queue AS
SELECT
    a.account_id,
    COALESCE(a.primary_opportunity, a.secondary_opportunity) AS product,
    c.campaign_id,
    c.campaign_code AS campaign,
    con.persona_type AS persona,
    con.contact_id AS contact,
    s.signal_type AS trigger,
    a.intent_score,
    CASE COALESCE(a.primary_opportunity,'')
        WHEN 'VAYU' THEN a.vayu_opportunity_score
        WHEN 'CYBER' THEN a.cyber_opportunity_score
        WHEN 'CIS' THEN a.cis_opportunity_score
    END AS product_score,
    a.icp_fit AS account_score,
    a.account_priority AS priority,
    'email' AS recommended_channel, -- overridden by orchestration logic per Section 13 journey
    a.next_best_action,
    c.status AS campaign_status,
    a.last_activity_at AS last_activity,
    NULL::TIMESTAMPTZ AS next_action,
    a.sales_status
FROM account a
LEFT JOIN contact con ON con.account_id = a.account_id AND con.is_primary_contact = TRUE
LEFT JOIN campaign c ON c.campaign_id = a.active_campaign_lock
LEFT JOIN signal s ON s.account_id = a.account_id
WHERE a.account_priority IN ('High','Medium')
  AND a.sales_status IS DISTINCT FROM 'handed_off';
