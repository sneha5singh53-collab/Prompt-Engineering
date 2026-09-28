-- TCL AI Demand Generation Engine — SQL Qualification Model (Section 4 & 13)
-- Configurable via config/scoring/weights.json -> qualification_floors
-- Params below are placeholders substituted by n8n at query time from that config file.

-- Hard exclusion list applied BEFORE any positive classification (Section 4 "Do NOT count").
-- A response must clear this filter to even be eligible for positive classification.
WITH excluded_response_types AS (
    SELECT unnest(ARRAY[
        'email_open',
        'generic_click',
        'auto_reply',
        'out_of_office',
        'send_me_information',   -- generic interest, not a qualified signal per spec
        'unsubscribe',
        'bounce'
    ]) AS excluded_type
),

eligible_responses AS (
    SELECT r.*
    FROM response r
    WHERE r.classified_as NOT IN (SELECT excluded_type FROM excluded_response_types)
),

positive_engagement AS (
    SELECT DISTINCT o.account_id
    FROM eligible_responses r
    JOIN outreach o ON o.outreach_id = r.outreach_id
    WHERE r.classified_as IN ('positive_business_reply','meeting_requested','specific_question')
),

strong_independent_signal AS (
    SELECT DISTINCT s.account_id
    FROM signal s
    WHERE s.decay_applied_score >= 20   -- high-weight signal threshold, tune per product
      AND s.signal_date >= CURRENT_DATE - INTERVAL '60 days'  -- sql_trigger_max_age_days
),

persona_matched_contact AS (
    SELECT DISTINCT c.account_id
    FROM contact c
    WHERE c.persona_type IS NOT NULL
      AND c.suppression_flag = FALSE
      AND c.email_verified = TRUE
),

recent_trigger AS (
    SELECT DISTINCT s.account_id, s.product_id, s.signal_type AS trigger_type, s.signal_date
    FROM signal s
    WHERE s.signal_date >= CURRENT_DATE - INTERVAL '60 days'  -- sql_trigger_max_age_days
)

SELECT
    a.account_id,
    a.company_name,
    COALESCE(a.primary_opportunity, a.secondary_opportunity) AS product,
    CASE COALESCE(a.primary_opportunity,'')
        WHEN 'VAYU' THEN a.vayu_opportunity_score
        WHEN 'CYBER' THEN a.cyber_opportunity_score
        WHEN 'CIS' THEN a.cis_opportunity_score
    END AS product_score,
    a.intent_score,
    rt.trigger_type,
    rt.signal_date AS trigger_date,
    (pe.account_id IS NOT NULL) AS has_positive_engagement,
    (sis.account_id IS NOT NULL) AS has_strong_independent_signal,
    CONCAT_WS(' | ',
        'Product score ' || CASE COALESCE(a.primary_opportunity,'')
            WHEN 'VAYU' THEN a.vayu_opportunity_score::TEXT
            WHEN 'CYBER' THEN a.cyber_opportunity_score::TEXT
            WHEN 'CIS' THEN a.cis_opportunity_score::TEXT
        END,
        'Intent ' || a.intent_score::TEXT,
        'Trigger: ' || COALESCE(rt.trigger_type, 'none'),
        CASE WHEN pe.account_id IS NOT NULL THEN 'Positive engagement confirmed'
             WHEN sis.account_id IS NOT NULL THEN 'Strong independent buying signal confirmed'
             ELSE 'INSUFFICIENT' END
    ) AS reason_for_sales_followup
FROM account a
JOIN recent_trigger rt ON rt.account_id = a.account_id
JOIN persona_matched_contact pmc ON pmc.account_id = a.account_id
LEFT JOIN positive_engagement pe ON pe.account_id = a.account_id
LEFT JOIN strong_independent_signal sis ON sis.account_id = a.account_id
WHERE
    CASE COALESCE(a.primary_opportunity,'')
        WHEN 'VAYU' THEN a.vayu_opportunity_score
        WHEN 'CYBER' THEN a.cyber_opportunity_score
        WHEN 'CIS' THEN a.cis_opportunity_score
    END >= 65   -- sql_min_product_score
    AND a.intent_score >= 60   -- sql_min_intent_score
    AND (pe.account_id IS NOT NULL OR sis.account_id IS NOT NULL)  -- rule 5: engagement OR strong signal
    AND a.sales_status IS DISTINCT FROM 'handed_off';
