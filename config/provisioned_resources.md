# Provisioned Resources — Live

| Resource | Where | Reference |
|---|---|---|
| Central Postgres database (13 tables + `tcl_activation_queue` view, schema per `config/data_model.sql`) | Supabase, via Lovable project **"Data Hearth"** | project_id: `9586b723-98de-4205-93c6-7556166820bf` — editor: https://lovable.dev/projects/9586b723-98de-4205-93c6-7556166820bf |
| `product` table | seeded | 3 rows: PROD-VAYU, PROD-CYBER, PROD-CIS |
| `campaign` table | seeded | 19 rows (V1–V6, C1–C6, I1–I7), all `status='draft'`, `is_active=false` until Section 27 human-approval gate is passed |
| Live sales SQL tracker (Section 20 handoff format, sales-editable) | Google Sheets | "TCL Activation Queue and Sales SQL Tracker" — https://docs.google.com/spreadsheets/d/1oO9naedDn0P_S5kTX6eVkqSFJLwT6IPVKEgB_BT3TAM/edit |
| Account source file | uploaded (TAL_FY_26.xlsx) | profiled in `config/data_profile_TAL_FY_26.md` — imported into Postgres, see below |

**Account/contact import — DONE (verified 2026-09-29):**
- `account`: 9,186 rows (1 skipped for blank name/id) — High 311, Medium 1,716, Low 5,111, suppressed (NULL priority) 2,048
- `contact`: 11,710 rows, 0 orphans (all linked to a loaded account), 380 marked `is_primary_contact` (MQL/Nurture/Callback), 2,824 with a verified email
- `suppression`: 4,337 rows (2,048 account-scope + 2,289 contact-scope)
- Loaded by attaching the source file directly to the Lovable project's own agent, which wrote and ran a Python/psql script inside its sandbox (bulk COPY) — far more efficient than streaming ~21k rows through chat context. Mapping rules matched `config/data_profile_TAL_FY_26.md` exactly (Account Status → account_priority/next_best_action/suppression per the table there; Contact Status → is_primary_contact/suppression_flag).

**n8n write access:** the n8n MCP connection in this session can only *read and execute* existing workflows (`search_workflows`, `get_workflow_details`, `execute_workflow`) — it cannot create or edit workflows, and this sandbox's network policy also blocks direct HTTPS calls to the user's n8n Cloud instance (`denave-marketing.app.n8n.cloud`) even with a valid API key (403 from the egress proxy — confirmed, not a bad key). Until that's resolved, the deliverable for each workflow (WF-00 onward) is an importable n8n workflow JSON file, not a live-deployed workflow.

**Clay:** the connected Clay workspace exposes only 5 domain-input subroutines (funding, tech stack, traffic, work email, phone) — no name→domain company resolution. User decided to proceed without it for now (fast-track the 311 High + 1,716 Medium priority accounts first); revisit once Clay is configured with a company-search enrichment.
