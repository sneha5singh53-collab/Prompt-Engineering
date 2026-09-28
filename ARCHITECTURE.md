# TCL AI Demand Generation Engine — Phase 1 Architecture

**Status:** Draft for validation — no n8n JSON has been generated yet, per build-phase instructions (architecture must be signed off first).
**Owner inputs locked in:** Account universe = external CSV/XLSX (not yet in a connected system) · No formal CRM — sales handoff is notification-based · Primary enrichment engine = Clay.
**Open decision carried forward:** the central relational data store (Section 6) and the sales-notification channel (Section 11) — flagged inline, recommended defaults given, confirm before Phase 2.

---

## 1. Architecture Diagram

```
                                   ┌────────────────────────────┐
                                   │   9,000+ ACCOUNT UNIVERSE   │
                                   │  (source: external CSV/XLSX)│
                                   └──────────────┬──────────────┘
                                                  │ one-time + delta import
                                                  ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              n8n ORCHESTRATION LAYER                              │
│                                                                                     │
│  L1 Ingest/Normalise → L2 ICP Score → L3 Product Score (Vayu/Cyber/CIS)            │
│        → L4 Intent/Signal Detect → L5 Deep Research (Clay) → L6 Contact Discovery  │
│        → L7 Personalisation (Claude) → L8 Outreach Dispatch (Lemlist)              │
│                                                                                     │
│   ┌───────────────┐   ┌───────────────┐   ┌───────────────┐   ┌────────────────┐  │
│   │ Scoring Engine │   │ Signal Engine │   │ Persona Engine│   │ Campaign Router │  │
│   │ (Code nodes +  │   │ (config-driven│   │ (trigger→role │   │ (account→micro- │  │
│   │  DB read/write) │   │  weights)     │   │  mapping)     │   │  campaign)      │  │
│   └───────────────┘   └───────────────┘   └───────────────┘   └────────────────┘  │
│                                                                                     │
│   ┌────────────────────────── DAILY OPERATING LOOP (08:00) ────────────────────┐  │
│   │ Refresh signals → Score → Build TCL_ACTIVATION_QUEUE → Generate            │  │
│   │ personalisation → Push to Lemlist → Poll engagement → Classify →           │  │
│   │ Update scores → SQL handoff → Nurture routing → EOD report                  │  │
│   └───────────────────────────────────────────────────────────────────────────┘  │
└───────────────────┬───────────────────────────────────────┬───────────────────────┘
                     │                                       │
                     ▼                                       ▼
        ┌─────────────────────────┐              ┌─────────────────────────────┐
        │   CENTRAL DATA STORE     │◄────────────►│   Clay (research/enrichment) │
        │ (Postgres/Airtable — TBD)│              │   Apollo/other — only if     │
        │ ACCOUNT/CONTACT/PRODUCT/ │              │   Clay coverage gaps found   │
        │ CAMPAIGN/SIGNAL/INTENT/  │              └─────────────────────────────┘
        │ ACTIVITY/OUTREACH/       │
        │ RESPONSE/LEAD/           │              ┌─────────────────────────────┐
        │ SALES_HANDOFF/NURTURE/   │◄────────────►│   Lemlist (execution layer)  │
        │ SUPPRESSION              │              │   campaigns, sequences,      │
        └───────────┬──────────────┘              │   engagement webhooks        │
                    │                              └─────────────────────────────┘
                    ▼
        ┌─────────────────────────┐
        │  SALES HANDOFF CHANNEL   │   → Sales brief per SQL (Section 20 format)
        │  (Gmail digest + shared  │
        │  log — channel TBD)      │
        └─────────────────────────┘
                    │
                    ▼
        ┌─────────────────────────┐
        │   DAILY REPORT (EOD)     │
        └─────────────────────────┘
```

**Control plane:** every arrow above is an n8n workflow or sub-workflow. n8n never lets an account enter two colliding outreach tracks simultaneously — enforced by an `active_campaign_lock` field on ACCOUNT, checked before any campaign-entry workflow runs (Section 12 requirement).

---

## 2. 9,000-Account Processing Strategy

The universe is **never processed at uniform depth** — cost and AI-call volume scale with the funnel, not the base.

| Level | Action | Trigger to advance | Expected population at this level (illustrative, recalibrate after Phase 2 data pull) |
|---|---|---|---|
| L1 | Normalise & dedupe raw CSV into ACCOUNT table | All 9,000+ | 9,000+ |
| L2 | ICP fit scoring (firmographic only — no AI calls) | All L1 accounts, refreshed weekly | 9,000+ |
| L3 | Product-fit scoring (VAYU/CYBER/CIS_FIT) — rules + lightweight AI classification | ICP_FIT ≥ configurable floor (default 40/100) | ~3,000–4,500 (est.) |
| L4 | Signal/intent detection (job postings, news, hiring — Clay data points, no deep research yet) | Product fit ≥ floor on ≥1 product | Same set as L3 |
| L5 | Deep AI-assisted research (Clay custom data points + Claude synthesis) | INTENT_SCORE ≥ configurable floor (default 60/100) OR ACCOUNT_PRIORITY = High | Top ~300–500/week (capacity-bound, see Section 14) |
| L6 | Contact discovery (persona-matched, Clay/Lemlist people database) | Passed L5 with a defined trigger + product angle | Same set as L5 |
| L7 | Personalisation generation (trigger-led message, Claude) | Verified contact found | Same set as L6 |
| L8 | Outreach dispatch to Lemlist | Passed campaign-collision + suppression checks | Bounded by daily activation queue capacity (Section 14) |

This keeps AI/API spend proportional to accounts that could plausibly become one of the 10 daily SQLs, not the full 9,000.

---

## 3–5. Product Opportunity Models

Each model follows the same shape: **business situation → problem → product angle → why → persona → trigger → outreach angle** (per Section 6 requirement). Full signal/persona/campaign detail is in Sections 7–9; this section defines the *scoring logic*.

### 3. VAYU_OPPORTUNITY_SCORE (0–100)
```
VAYU_FIT = (ICP_weight × ICP_component)
         + (signal_weight × VAYU_SIGNAL_SCORE)     ← Section 7
         + (trigger_recency_weight × recency_decay)
         + (engagement_weight × VAYU_ENGAGEMENT_HISTORY)
```
Component drivers (all weights configurable in `config/scoring/weights.json`):
- Company scale/growth trajectory (headcount growth, funding, expansion) → cloud modernisation / cost pressure likelihood
- Technical hiring signal density (AI/ML/data/cloud roles) → AI infra / GPU likelihood
- Regulated industry flag (BFSI, healthcare, government, PSU) → sovereign/regulated workload likelihood
- Existing multi-cloud/hybrid footprint signals (from Clay tech-stack data point) → hybrid/private cloud likelihood
- Data residency sensitivity (industry + geography combination) → data sovereignty likelihood

### 4. CYBER_OPPORTUNITY_SCORE (0–100)
```
CYBER_FIT = (ICP_weight × ICP_component)
          + (signal_weight × CYBER_SIGNAL_SCORE)   ← Section 7
          + (trigger_recency_weight × recency_decay)
          + (engagement_weight × CYBER_ENGAGEMENT_HISTORY)
```
Component drivers:
- CISO/security leadership hire or org restructuring signal
- Compliance-driven industry (BFSI, healthcare, critical infra, government)
- Cloud footprint expansion (cloud growth without matched security signal = latent need)
- Public incident/breach disclosure (highest-weight single signal, time-decayed fast)
- SOC/security team headcount growth or absence relative to company size

### 5. CIS_OPPORTUNITY_SCORE (0–100)
```
CIS_FIT = (ICP_weight × ICP_component)
        + (signal_weight × CIS_SIGNAL_SCORE)       ← Section 7
        + (trigger_recency_weight × recency_decay)
        + (engagement_weight × CIS_ENGAGEMENT_HISTORY)
```
Component drivers:
- Customer-facing digital product launches (app, portal, e-commerce)
- Contact-centre or CX team hiring/expansion
- Transaction/auth-heavy business model (fintech, e-commerce, delivery, BFSI onboarding)
- Geographic/market expansion (new country = new comms infra need)
- Marketing/comms team growth (campaign volume proxy)

**Output per account (example, per spec Section 5):**
```json
{"account_id":"A-04821","company":"ABC","vayu_opportunity_score":87,"cyber_opportunity_score":61,
 "cis_opportunity_score":29,"primary_opportunity":"VAYU","secondary_opportunity":"CYBER",
 "active_campaign_lock":null}
```

---

## 6. Product-Specific ICP

All three share a base ICP filter (company must clear this before any product score is computed), then diverge:

**Base ICP filter:** operating company (not shell/holding), verifiable domain, minimum employee count (default 200, configurable), active in last 12 months (not defunct/acquired-and-dissolved), geography within TCL's served markets.

| Dimension | VAYU ICP | CYBER ICP | CIS ICP |
|---|---|---|---|
| Best-fit industries | BFSI, manufacturing, healthcare, media/entertainment, government/PSU, tech/SaaS with scaling infra needs | BFSI, healthcare, critical infrastructure, government, any regulated industry | BFSI, e-commerce/retail, telecom, travel, logistics, healthcare (patient comms), fintech |
| Company stage signal | Scaling / expanding infra footprint | Any stage, weighted toward regulatory exposure | High transaction/customer-interaction volume |
| Technology maturity | Multi-cloud or cloud-curious; visible cloud/data job reqs | Any; gap between security maturity and cloud/digital exposure is the signal | Digital-first customer engagement model |
| Org signal | Exists: CIO/CTO/Head of Infra function | Exists: CISO/security function, OR notably absent for its risk profile | Exists: CX/Customer Ops/Digital function |
| Disqualifiers | Pure on-prem, no digital roadmap | No regulatory exposure and no data sensitivity | No direct customer communication ownership (pure B2B2B with no end-customer touch) |

---

## 7. Product-Specific Buying Signals (weights configurable — see `config/scoring/weights.json`)

| VAYU signal | Default weight | CYBER signal | Default weight | CIS signal | Default weight |
|---|---|---|---|---|---|
| AI/ML hiring surge | 20 | CISO appointment | 25 | High-volume transactional comms need (OTP/auth) | 20 |
| GPU/infra job requirements | 20 | Security incident/breach disclosure | 25 | New mobile/digital app launch | 18 |
| Cloud migration announcement | 18 | Compliance initiative (new regulation exposure) | 18 | Contact-centre expansion | 16 |
| Data centre expansion | 15 | Zero Trust / SSE initiative | 15 | Customer growth (reported/inferred) | 15 |
| New AI product launch | 15 | Cloud expansion w/o matched security hire | 15 | International/market expansion | 14 |
| Cloud cost pressure signal (layoffs + infra spend news) | 12 | SOC expansion/build | 12 | Omnichannel/UC transformation signal | 12 |
| Data sovereignty/regulatory trigger | 12 | Security hiring (non-CISO) | 10 | Voice/UC transformation initiative | 10 |
| Hybrid/private cloud RFP or vendor-review signal | 10 | Regulatory pressure (industry-wide) | 10 | Marketing comms volume expansion | 8 |

Signal scores are **time-decayed** (default half-life 45 days) so a 6-month-old hiring spike doesn't outrank a fresh trigger — decay curve is configurable per product.

---

## 8. Product-Specific Buying Personas

| Product | Primary personas (in priority order) | Persona selection logic |
|---|---|---|
| VAYU | CIO → CTO → Head of Cloud → Head of Infrastructure → Head of AI/Data → VP Technology → IT Director | Trigger type maps to persona: AI/GPU trigger → Head of AI/Data first; cost/modernisation trigger → CIO/CTO first |
| CYBER | CISO → CIO → CTO → Head of Cyber Security → Head of InfoSec → SOC Head → IT Security Head | CISO always first if the role exists at the account (from org signal in ICP); else escalate to CIO/CTO |
| CIS | Chief Customer Officer → CX Head → CMO → CIO/CTO → Digital Head → Contact Centre Head → Customer Service Head | Marketing-driven trigger (campaign comms) → CMO first; product/app trigger → Digital Head/CTO first |

The persona engine (n8n sub-workflow) resolves **trigger → candidate persona list → contact discovery attempt in order** until a verified contact is found; failure at every tier routes the account to `next_best_action = find_another_persona` (Section 17), not straight to nurture.

---

## 9. Product-Specific Campaign Matrix

| Code | Campaign | Activates on |
|---|---|---|
| V1 | AI/GPU infrastructure | VAYU signal set dominated by AI/ML hiring + GPU reqs |
| V2 | Cloud modernisation | Cloud migration / legacy modernisation signal |
| V3 | Sovereign cloud | Regulated industry + data residency signal |
| V4 | Hybrid/private cloud | Multi-cloud footprint + hybrid RFP signal |
| V5 | Regulated workloads | Regulated industry ICP + compliance trigger |
| V6 | Cloud cost/complexity | Cost-pressure signal (layoffs/spend news combo) |
| C1 | Cloud security | Cloud expansion without matched security hire |
| C2 | Cyber resilience | Incident/breach disclosure |
| C3 | Security transformation | Zero Trust/SSE initiative signal |
| C4 | SOC/managed security | SOC expansion or absent SOC at scale |
| C5 | Compliance/security | Regulatory-exposure trigger |
| C6 | SSE/secure access | Hybrid workforce + access signal |
| I1 | Customer communication | General CX/comms trigger, no sharper signal |
| I2 | OTP/authentication | Fintech/auth-heavy trigger |
| I3 | Transactional messaging | High transaction-volume signal |
| I4 | Customer service | Contact-centre/service org signal |
| I5 | Cloud voice | Voice/UC infra trigger |
| I6 | Unified communications | Internal comms/UC transformation signal |
| I7 | CX transformation | Broad digital CX initiative signal |

**Activation rule (Section 11 requirement):** only campaigns with a live trigger match in the current activation queue are turned on for a given account-day; nothing runs speculatively. The campaign router selects **one** campaign per product per account at a time — if an account qualifies for two campaigns in the same product, the higher-scoring trigger wins and the other is logged as a queued alternate.

---

## 10–11. Connector Audit & Minimum Tech Stack

**Already connected in this environment (confirmed live):**

| Connector | Role in this engine |
|---|---|
| **n8n** | Orchestration layer — every workflow in Sections 1, 14, 19 |
| **Lemlist** | Execution layer — campaigns, sequences, watch lists, engagement webhooks, people database, AI variable prompts (Section 12) |
| **Clay** | Primary enrichment/research engine (your choice) — company/contact data points, custom research questions, subroutines |
| **HubSpot** | Available but **not selected** as system of record (you chose notify-only) — kept in reserve; trivial to promote later since the connector is already live |
| **Apollo.io** | Available as secondary enrichment/contact-discovery fallback if Clay has coverage gaps on a specific account |
| **Gmail** | Candidate channel for sales-brief notification and EOD report delivery |
| **Google Drive** | Candidate store for the raw account CSV/XLSX and generated reports |
| **Google Calendar** | Candidate for Day-8 call-task scheduling / meeting booking (Section 13) |
| **Notion** | Candidate for the daily report / sales handoff log surface if a lightweight shared doc is preferred over email |

**Gap requiring a decision (not yet connected, needed regardless of choice):**

| Need | Options | Recommendation |
|---|---|---|
| Central relational data store (ACCOUNT/CONTACT/.../SUPPRESSION, Section 26) | Postgres (via n8n's native DB node), Airtable, Google Sheets | **Postgres** — 9,000+ accounts with 13 linked entities and full journey history will outgrow Sheets/Airtable row-count and relational-integrity limits within weeks. Airtable acceptable only if the team explicitly wants a no-code UI over raw SQL. |
| Sales notification channel | Gmail digest, Notion page/database, Slack (not connected) | **Gmail (per-SQL brief) + Notion (running SQL log/dashboard)** — both already connected, no new connector needed. |

**No other new tool is recommended.** Calling (Section 13, Day-8 task) is modeled as a **task**, not an automated dial — a human rep calls from the brief; no dialer integration is in scope for Phase 1.

---

## 12. Data Model

Thirteen entities per Section 26, all with `created_at`/`updated_at`/`source` audit fields.

```sql
ACCOUNT(account_id PK, company_name, domain, industry, employee_count, geography,
        icp_fit, vayu_fit, cyber_fit, cis_fit, vayu_opportunity_score, cyber_opportunity_score,
        cis_opportunity_score, primary_opportunity, secondary_opportunity, intent_score,
        engagement_score, account_priority, account_stage, active_campaign_lock,
        nurture_level, next_best_action, sales_status, last_activity_at)

CONTACT(contact_id PK, account_id FK, full_name, title, persona_type, email, linkedin_url,
        email_verified, is_primary_contact, suppression_flag)

PRODUCT(product_id PK, product_name, product_group, knowledge_base_ref)

CAMPAIGN(campaign_id PK, campaign_code, product_id FK, name, status, lemlist_campaign_id,
         activation_rule, is_active)

SIGNAL(signal_id PK, account_id FK, product_id FK, signal_type, signal_source, signal_date,
       confidence, weight_applied, decay_applied_score)

INTENT(intent_id PK, account_id FK, product_id FK, intent_score, computed_at, driving_signals[])

ACTIVITY(activity_id PK, account_id FK, contact_id FK, activity_type, channel, occurred_at,
         detail_ref)

OUTREACH(outreach_id PK, account_id FK, contact_id FK, campaign_id FK, sequence_step,
         sent_at, message_variant, status)

RESPONSE(response_id PK, outreach_id FK, response_type, sentiment, received_at, classified_as,
         routed_action)

LEAD(lead_id PK, account_id FK, contact_id FK, product_id FK, qualified_at, qualification_reason,
     status)

SALES_HANDOFF(handoff_id PK, lead_id FK, brief_ref, sent_to_sales_at, sales_feedback,
               feedback_classification, feedback_at)

NURTURE(nurture_id PK, account_id FK, nurture_level, entered_at, reactivation_trigger,
        reactivated_at)

SUPPRESSION(suppression_id PK, contact_id FK, account_id FK, reason, suppressed_at, scope)
```

Every ACCOUNT has a full journey history reconstructable by joining SIGNAL → INTENT → OUTREACH → RESPONSE → LEAD → SALES_HANDOFF on `account_id`, ordered by timestamp (Section 26 requirement).

---

## 13. SQL Qualification Model (configurable)

An account/contact becomes a **Sales Qualified Lead** only when ALL of the following are true — see `config/sql_qualification.sql` for the literal, tunable query:

1. `product_score >= config.sql_min_product_score` (default 65/100) for the product being pursued
2. `intent_score >= config.sql_min_intent_score` (default 60/100)
3. A `trigger` record exists on the account dated within `config.sql_trigger_max_age_days` (default 60 days)
4. A `persona_match = true` contact exists (correct persona tier per Section 8)
5. **Either** meaningful engagement (`response.classified_as IN ('positive_business_reply','meeting_requested','specific_question')`) **OR** a strong independent buying signal (`signal.signal_type IN (high-weight list)` at ≥ threshold) — explicitly excluding opens, generic clicks, "send me info," and auto-replies (hard-excluded at the classifier level, not just unweighted)
6. A documented `reason_for_sales_followup` string is generated (non-empty) — no SQL is created without one

Rule 5's exclusion list is enforced as a **negative filter before positive classification runs** — a reply is never allowed to reach "qualified" status through pattern-matching alone; the response-classification workflow (Section 19) must assign a positive category explicitly.

---

## 14. Daily 10-SQL Operating Model

Each morning (08:00) the engine works backward from the target rather than pushing volume:

```
1. Pull current qualified pipeline count (LEAD table, status=open, today)
2. Pull accounts with account_priority=High AND next_best_action IN (send_email, follow_up, re_engage)
3. Pull available verified contacts against those accounts
4. Check campaign capacity (Lemlist sending limits, mailbox health, per-contact/account frequency caps)
5. Check trailing 14-day campaign performance (reply rate, SQL conversion by campaign)
6. Build TODAY'S ACTIVATION QUEUE, capped per product by current data quality, e.g.:
     VAYU: 4 priority opportunities | CYBER: 3 | CIS: 3
7. If total activatable < 10: report the true number and WHY — do not lower thresholds.
   Example output: "Only 7 accounts currently meet SQL activation criteria today.
   Shortfall: CYBER (need 3, have 1) — insufficient fresh signals in Level 4 this week.
   Recommended action: expand CYBER signal sourcing, not lower CYBER_FIT floor."
```

This queue-building logic is itself a config-driven n8n workflow (`workflow: daily-queue-builder`), not a fixed cron of sends — see Section 15 dependency map.

---

## 15. n8n Workflow Dependency Map

```
[WF-00 Data Ingest] ──▶ [WF-01 ICP Scoring] ──▶ [WF-02 Product Scoring (Vayu/Cyber/CIS)]
                                                        │
                                                        ▼
                                          [WF-03 Signal Refresh & Intent Scoring]
                                                        │
                                    ┌───────────────────┼───────────────────┐
                                    ▼                                       ▼
                    [WF-04 Deep Research (Clay)]                [WF-05 Account Priority Engine]
                                    │                                       │
                                    ▼                                       │
                    [WF-06 Persona & Contact Discovery] ◀───────────────────┘
                                    │
                                    ▼
                    [WF-07 Daily Queue Builder]  ← reads capacity, performance, thresholds
                                    │
                                    ▼
                    [WF-08 Campaign Selector & Collision Guard] (checks active_campaign_lock)
                                    │
                                    ▼
                    [WF-09 Personalisation Generator]
                                    │
                                    ▼
                    [WF-10 Lemlist Dispatch]
                                    │
                                    ▼
        ┌───────────────────────────────────────────────────────────┐
        ▼                           ▼                                ▼
[WF-11 Engagement Webhook   [WF-12 Account-Level Intent   [WF-13 Response Classifier
  Listener (Lemlist)]         Rollup (multi-contact)]       & SQL Qualifier]
        │                           │                                │
        └───────────────┬───────────┘                                ▼
                         ▼                                [WF-14 Sales Handoff Brief Generator]
              [WF-15 Nurture Router]                                  │
              (Hot/Warm/Cold-but-fit)                                 ▼
                         │                                 [WF-16 Sales Notification Dispatch]
                         ▼
              [WF-17 Reactivation Trigger Monitor]
                         │
                         ▼
              [WF-18 EOD Daily Report Generator]

Cross-cutting (called by multiple workflows, built once):
  [WF-90 Suppression/Unsubscribe Check]  [WF-91 Frequency Cap Check]
  [WF-92 AI Cost Guard]                  [WF-93 Audit Log Writer]
```

**Recommended build order for Phase 2 onward:** WF-00 → WF-01 → WF-02 (this is the "account foundation," Build Phase 2) before any signal/research/outreach workflow — matches Section 29's phase ordering.

---

## Governance defaults carried into every workflow (Section 27)

- No credential is ever hard-coded — all API keys via n8n credential store.
- `SUPPRESSION` and `active_campaign_lock` checks are the **first** node in WF-08 and WF-10, not an afterthought.
- Every AI call (Clay research, Claude personalisation) is logged with cost against a daily/weekly AI budget cap (WF-92); the run halts and alerts rather than silently overspending.
- New campaigns (new V/C/I code) require a human-approval node before `is_active=true` — never auto-activated by the scoring engine alone.

---

## Next step

This document is the Phase 1 deliverable for sign-off. Once approved:
1. Confirm the central data store choice (Postgres recommended) and notification channel (Gmail+Notion recommended).
2. Share the account CSV/XLSX (or its location) so WF-00 can be scoped against real columns.
3. I build **only** WF-00 → WF-02 first (Build Phase 2 — account foundation + scoring), validate against real data, then proceed workflow-by-workflow per the dependency map — no bulk JSON generation before that.
