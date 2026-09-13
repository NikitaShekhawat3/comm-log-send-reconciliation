# Comm-Log Send Reconciliation

## Result

For merchant `501`, October 2026, campaign communications (`communication_type = '2'`), I reproduce Finance's `target_base` of **22**.

## Reconciliation bridge

| Step | Description | Result | Change | Reason |
|---:|---|---:|---:|---|
| 0 | Naive count of scoped `communication_log` send attempts | 30 | — | This is the most direct interpretation: each log row is a send. |
| 1 | Keep only campaigns eligible for reporting | 26 | -4 | Campaign `9004` is `approval_awaiting`, so its four logged sends are not reportable despite having been processed. |
| 2 | Tried a naive `COUNT(DISTINCT customer_id)` across all eligible sends | 21 | -5 | **Wrong turn.** This silently collapses `C20`'s second send under standalone campaign `9101` into `C20`'s first, treating a legitimate re-target as if it were a retry. Global distinct-customer dedup can't be applied blindly across campaigns that have no retry relationship. |
| 3 | Dedup only within retry-linked families (by `parent_id` chain); keep every standalone send as its own event | 22 | +1 | Recovers `C20`'s second send. Family 9001 -> 9002 -> 9003 removes three duplicate retry attempts: one additional attempt for C2 and two for C3; family `9201 -> 9202` collapses 1 (`D1`). Retry and repeat-targeting are different relationships and need different treatment. |
| Final | `target_base` | **22** |  |  |

## Important interpretation check

I did **not** globally deduplicate customers within every campaign. `9101` is a standalone campaign, and its two sends to `C20` are legitimate separate events under the stated metric. It remains at 7 events (not 6). The SQL therefore deduplicates only campaign families that actually have a retry relationship, and preserves all standalone send events.

I also deliberately did **not** filter on `delivery_status` (`900`/`1100`). A failed attempt (`1100`) inside a retry chain isn't dropped from consideration, it's just superseded once the chain is collapsed to one row per customer, because the later, delivered attempt (or the failed one, if that's all there is) resolves to the same customer either way. `delivery_status` explains *why* a retry chain exists in the first place; it isn't itself a gate on whether a send qualifies for `target_base`.

## SQL

Run [`reconciliation.sql`](reconciliation.sql) against the supplied `comm_log.db`; it returns one row with `target_base = 22`.

Example:

```sh
sqlite3 data/comm_log.db < reconciliation.sql
```

## Investigation notes / surprise

The most surprising point was that `9004` already had four send-log rows and a completed processing status, yet it was still excluded because its **creation** workflow was `approval_awaiting`. I also found that duplicate-looking rows cannot be handled with a blanket `DISTINCT customer_id`: the duplicate for `C20` in standalone campaign `9101` is explicitly a real re-targeting event, whereas repeated customers across `parent_id` retry chains represent the same underlying communication. That distinction is what turns the eligible 26 sends into 22 rather than 21.
