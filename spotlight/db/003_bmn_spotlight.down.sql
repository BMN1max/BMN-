-- Rollback of 003_bmn_spotlight.up.sql. Refuses to delete announcements unless you confirm:  SET bmn.confirm_rollback = 'yes';
BEGIN;
DO $$
BEGIN
  IF to_regclass('public.bmn_spotlights') IS NOT NULL
     AND ((SELECT count(*) FROM public.bmn_spotlights) > 0 OR (SELECT count(*) FROM public.bmn_spotlight_audit) > 0)
     AND COALESCE(current_setting('bmn.confirm_rollback', true), '') <> 'yes' THEN
    RAISE EXCEPTION 'Spotlight tables contain data. To delete it permanently run: SET bmn.confirm_rollback = ''yes''; and retry.' USING ERRCODE = '55000';
  END IF;
END $$;
DROP FUNCTION IF EXISTS public.bmn_spotlight_active(text);
DROP FUNCTION IF EXISTS public.bmn_spotlight_owner_list();
DROP FUNCTION IF EXISTS public.bmn_spotlight_owner_save(uuid, jsonb);
DROP FUNCTION IF EXISTS public.bmn_spotlight_owner_set_status(uuid, text);
DROP FUNCTION IF EXISTS public.bmn_spotlight_owner_delete(uuid);
DROP FUNCTION IF EXISTS public.bmn_spotlight_owner_audit(integer);
DROP FUNCTION IF EXISTS public.bmn_spotlight_assert_owner();
DROP FUNCTION IF EXISTS public.bmn_spotlight_state(public.bmn_spotlights);
DROP TABLE IF EXISTS public.bmn_spotlight_audit;
DROP TABLE IF EXISTS public.bmn_spotlights;
COMMIT;
