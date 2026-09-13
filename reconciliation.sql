-- Comm-log target_base reconciliation
-- SQLite; run against comm_log.db.
-- Expected result for the supplied data: 22.

WITH RECURSIVE
scoped_campaigns AS (
    SELECT id, merchant_id, parent_id, creation_status, processing_status
    FROM campaign
    WHERE merchant_id = 501
),
-- Attach every campaign to the first campaign in its retry family.
campaign_tree(root_campaign_id, campaign_id) AS (
    SELECT id, id
    FROM scoped_campaigns
    WHERE parent_id IS NULL

    UNION ALL

    SELECT tree.root_campaign_id, child.id
    FROM campaign_tree AS tree
    JOIN scoped_campaigns AS child
      ON child.parent_id = tree.campaign_id
),
-- Note: campaign_tree keeps every campaign in a family, including ineligible
-- ones (e.g. 9004, which is approval_awaiting). That's intentional -- tree
-- membership is a pure structural fact (who retries whom) and must not be
-- affected by eligibility. Eligibility is applied per-campaign below, in
-- eligible_sends, so an ineligible child's sends are dropped without
-- affecting how its eligible siblings/parent are grouped.
eligible_sends AS (
    SELECT
        tree.root_campaign_id,
        log.communication_id,
        log.customer_id
    FROM communication_log AS log
    JOIN scoped_campaigns AS campaign
      ON campaign.id = log.communication_id
    JOIN campaign_tree AS tree
      ON tree.campaign_id = campaign.id
    WHERE log.merchant_id = 501
      AND log.communication_type = '2'
      AND log.sent_time >= '2026-10-01'
      AND log.sent_time <  '2026-11-01'
      AND campaign.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
      AND campaign.processing_status = 'processed'
),
family_type AS (
    SELECT
        root_campaign_id,
        MAX(CASE WHEN campaign_id <> root_campaign_id THEN 1 ELSE 0 END) AS has_retry
    FROM campaign_tree
    GROUP BY root_campaign_id
),
retry_family_customers AS (
    -- A customer counts once across all eligible attempts in one retry family.
    SELECT DISTINCT send.root_campaign_id, send.customer_id
    FROM eligible_sends AS send
    JOIN family_type AS family
      ON family.root_campaign_id = send.root_campaign_id
    WHERE family.has_retry = 1
),
standalone_events AS (
    -- A standalone campaign has no retry relationship, so retain every send event.
    SELECT send.root_campaign_id, send.customer_id
    FROM eligible_sends AS send
    JOIN family_type AS family
      ON family.root_campaign_id = send.root_campaign_id
    WHERE family.has_retry = 0
)
SELECT COUNT(*) AS target_base
FROM (
    SELECT root_campaign_id, customer_id FROM retry_family_customers
    UNION ALL
    SELECT root_campaign_id, customer_id FROM standalone_events
);

-- Optional audit queries used for the reconciliation bridge:
--
-- 0) Naive count: 30
-- SELECT COUNT(*) FROM communication_log
-- WHERE merchant_id = 501 AND communication_type = '2'
--   AND sent_time >= '2026-10-01' AND sent_time < '2026-11-01';
--
-- 1) Applying the campaign reporting eligibility gate: 26
-- SELECT COUNT(*)
-- FROM communication_log AS log
-- JOIN campaign AS campaign ON campaign.id = log.communication_id
-- WHERE log.merchant_id = 501 AND log.communication_type = '2'
--   AND log.sent_time >= '2026-10-01' AND log.sent_time < '2026-11-01'
--   AND campaign.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
--   AND campaign.processing_status = 'processed';
