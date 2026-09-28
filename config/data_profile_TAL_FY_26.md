# Data Profile — TAL_FY_26.xlsx (received from user)

Source file: `TAL_FY_26.xlsx` — 2 sheets. This is the raw seed for the ACCOUNT and CONTACT tables (Section 26 data model). Findings below drive the WF-00 ingestion design.

## Account List sheet
- **9,187 rows**, 168 columns, single campaign tag (`FY-27 || NEW PEM MASTER TML`)
- Looks like a BPO/telemarketing MIS export template reused across clients — columns 157–166 ask about "Dell" specifically (e.g. "reason for not dealing with Dell", "start engaging with Dell again"). These are leftover from a different client's campaign and will be dropped/ignored for TCL.
- **Firmographic fields are present as columns but essentially empty**: Website 0.1% filled, Industry Segment 0% filled, No of Employees 0% filled, Country 100% blank. ICP/product scoring (Sections 3–6) cannot run off this file as-is — every account needs an enrichment pass (Clay) just to get industry/size/geography before any fit score is possible. This is expected and matches the L1→L2 flow in Section 2, but it means the *first* Clay spend is firmographic backfill across the full 9,187, not research on a shortlist.
- **Contact coverage is thin**: only 29.1% of accounts have any of the 5 contact-email slots filled.
- **Account Status breakdown** (use to seed SUPPRESSION and initial NEXT_BEST_ACTION):
  | Status | Count | Recommended handling |
  |---|---|---|
  | No Response | 2,556 | Re-enter at L2, treat as cold start |
  | (blank) | 2,527 | Re-enter at L2, treat as cold start |
  | Account Disqualified | 1,715 | Suppress by default |
  | Profiled | 996 | Skip to L3 (has some prior profiling) |
  | Follow Up | 720 | Priority re-check at L2 |
  | Bad Data | 289 | Suppress, flag for data-cleanup queue |
  | Lead | 174 | **Fast-track — highest near-term SQL potential** |
  | Pipeline | 126 | **Fast-track — already in a sales motion, verify before re-touching** |
  | DNC | 44 | Suppress — global, permanent |
  | In Progress | 11 | Fast-track |

  → **~2,048 accounts (22%) are recommended for immediate suppression** (Disqualified + Bad Data + DNC). ~1,300 (Lead+Pipeline+In Progress+Profiled) are the fastest path to early SQLs while the rest of the universe is being enriched.

## Contact List sheet
- **11,710 rows** (multiple contacts per account, matching the wide Contact1–5 columns on Account List)
- Email filled 24.1%, mobile filled 24.5%
- **Contact Status breakdown** — the most useful single field in the whole file:
  | Status | Count | Meaning for the engine |
  |---|---|---|
  | Interested - MQL | 174 | Already marketing-qualified — highest priority for persona/product mapping and fast SQL review |
  | Nurture | 146 | Seed the COLD_BUT_FIT nurture list directly |
  | Callback | 60 | Immediate call-task candidates |
  | Disqualified - No Interest / Out of Scope | 1,984 combined | Suppress |
  | Bad Data | 305 | Suppress, data-cleanup queue |
  | Call not connected / blank / Profiled / Follow UP | ~8,945 | Standard L2+ processing |

## Net effect on the WF-00 ingestion design
1. Map `CRM Org Id` → `account_id`, `Contactid*` → `contact_id` (these are the only reliable unique keys — no domain/website to match on).
2. No domain means Clay company-matching will run on **organisation name + address/city** rather than domain — expect a lower match/confidence rate than a domain-based lookup; flag low-confidence matches rather than silently accepting them (per the "SOURCE/DATE/CONFIDENCE" rule in Section 7 of the brief).
3. Drop the 10 "Dell"-specific columns (157–166) at ingestion — not relevant to TCL.
4. Apply the suppression list (Disqualified/Bad Data/DNC, ~2,048 accounts) as the first SUPPRESSION table write, before any scoring runs.
5. Fast-track Lead/Pipeline/MQL/Callback accounts (~460 total) through L2→L3 first — these can plausibly contribute to the 10-SQL/day target inside the first week, while firmographic enrichment runs on the broader 9,187 in the background.
