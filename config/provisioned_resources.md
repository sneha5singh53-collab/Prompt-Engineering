# Provisioned Resources — Live

| Resource | Where | Reference |
|---|---|---|
| Central Postgres database (13 tables + `tcl_activation_queue` view, schema per `config/data_model.sql`) | Supabase, via Lovable project **"Data Hearth"** | project_id: `9586b723-98de-4205-93c6-7556166820bf` — editor: https://lovable.dev/projects/9586b723-98de-4205-93c6-7556166820bf |
| `product` table | seeded | 3 rows: PROD-VAYU, PROD-CYBER, PROD-CIS |
| `campaign` table | seeded | 19 rows (V1–V6, C1–C6, I1–I7), all `status='draft'`, `is_active=false` until Section 27 human-approval gate is passed |
| Live sales SQL tracker (Section 20 handoff format, sales-editable) | Google Sheets | "TCL Activation Queue and Sales SQL Tracker" — https://docs.google.com/spreadsheets/d/1oO9naedDn0P_S5kTX6eVkqSFJLwT6IPVKEgB_BT3TAM/edit |
| Account source file | uploaded (TAL_FY_26.xlsx) | profiled in `config/data_profile_TAL_FY_26.md` — not yet imported into Postgres |

**Not yet done:** importing the 9,187 accounts / 11,710 contacts from TAL_FY_26.xlsx into the `account`/`contact` tables, and applying the suppression list (Disqualified/Bad Data/DNC ≈ 2,048 accounts) — next step.

**n8n write access:** the n8n MCP connection in this session can only *read and execute* existing workflows (`search_workflows`, `get_workflow_details`, `execute_workflow`) — it cannot create or edit workflows. Until the user provides broader n8n API access, the deliverable for each workflow (WF-00 onward) is an importable n8n workflow JSON file, not a live-deployed workflow.
