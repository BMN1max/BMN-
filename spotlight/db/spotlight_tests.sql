-- Spotlight DB tests. Run by run_spotlight_tests.sh AFTER shim + baseline + harness + seed + 003 UP. Disposable local DB only.
SELECT pgtest.u(1) AS owner \gset
-- grants for the test roles on the tables the baseline owns are not needed: Spotlight uses only functions.

-- ---- lockdown
SELECT pgtest.t('L1 anon cannot read the table directly', $$SELECT * FROM public.bmn_spotlights$$, 'anon', NULL, '42501');
SELECT pgtest.t('L2 signed-in user cannot read the table directly', $$SELECT * FROM public.bmn_spotlights$$, 'authenticated', pgtest.u(2), '42501');
SELECT pgtest.t('L3 signed-in user cannot insert directly', $$INSERT INTO public.bmn_spotlights (kind,title,status) VALUES ('holiday','x','published')$$, 'authenticated', pgtest.u(2), '42501');
SELECT pgtest.t('L4 owner (as a normal signed-in role) cannot write the table directly either', $$INSERT INTO public.bmn_spotlights (kind,title) VALUES ('holiday','x')$$, 'authenticated', pgtest.u(1), '42501');
SELECT pgtest.t('L5 nobody can read the audit table directly', $$SELECT * FROM public.bmn_spotlight_audit$$, 'authenticated', pgtest.u(1), '42501');
SELECT pgtest.q('L6 RLS is on for both tables', $$(SELECT bool_and(relrowsecurity) FROM pg_class WHERE oid IN ('public.bmn_spotlights'::regclass,'public.bmn_spotlight_audit'::regclass))$$);
SELECT pgtest.q('L7 anon may execute only bmn_spotlight_active',
  $$has_function_privilege('anon','public.bmn_spotlight_active(text)','EXECUTE')
    AND NOT has_function_privilege('anon','public.bmn_spotlight_owner_list()','EXECUTE')
    AND NOT has_function_privilege('anon','public.bmn_spotlight_owner_save(uuid,jsonb)','EXECUTE')
    AND NOT has_function_privilege('anon','public.bmn_spotlight_owner_set_status(uuid,text)','EXECUTE')
    AND NOT has_function_privilege('anon','public.bmn_spotlight_owner_delete(uuid)','EXECUTE')
    AND NOT has_function_privilege('anon','public.bmn_spotlight_owner_audit(integer)','EXECUTE')$$);
SELECT pgtest.q('L8 every SECURITY DEFINER spotlight function pins search_path',
  $$(SELECT bool_and(p.proconfig @> ARRAY['search_path=""']) FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname LIKE 'bmn_spotlight%' AND p.prosecdef)$$);

-- ---- owner gate
SELECT pgtest.t('O1 anon cannot call owner_list', $$SELECT public.bmn_spotlight_owner_list()$$, 'anon', NULL, '42501');
SELECT pgtest.t('O2 normal user cannot call owner_list', $$SELECT public.bmn_spotlight_owner_list()$$, 'authenticated', pgtest.u(2), '42501');
SELECT pgtest.t('O3 normal user cannot save', $$SELECT public.bmn_spotlight_owner_save(NULL, '{"kind":"holiday","title":"Nope"}')$$, 'authenticated', pgtest.u(2), '42501');
SELECT pgtest.t('O4 normal user cannot change status', $$SELECT public.bmn_spotlight_owner_set_status(gen_random_uuid(),'published')$$, 'authenticated', pgtest.u(2), '42501');
SELECT pgtest.t('O5 normal user cannot delete', $$SELECT public.bmn_spotlight_owner_delete(gen_random_uuid())$$, 'authenticated', pgtest.u(2), '42501');
SELECT pgtest.t('O6 normal user cannot read the audit', $$SELECT public.bmn_spotlight_owner_audit(10)$$, 'authenticated', pgtest.u(2), '42501');
SELECT pgtest.t('O7 owner can list (empty at first)', $$SELECT public.bmn_spotlight_owner_list()$$, 'authenticated', pgtest.u(1));
SELECT pgtest.q('O8 nothing is seeded: the table starts empty, active feed is empty', $$(SELECT count(*)=0 FROM public.bmn_spotlights) AND public.bmn_spotlight_active('search')->'items' = '[]'::jsonb$$);

-- ---- create / validation (as owner)
CREATE TEMP TABLE sp_ids (k text PRIMARY KEY, id uuid);
GRANT ALL ON sp_ids TO authenticated;
SELECT pgtest.t('C1 owner creates a draft', $$INSERT INTO sp_ids SELECT 'draft', (public.bmn_spotlight_owner_save(NULL,'{"kind":"holiday","title":"Independence Day","subtitle":"Happy holiday","emoji":"🎉","link_url":"/events/holiday"}')->>'id')::uuid$$, 'authenticated', pgtest.u(1));
SELECT pgtest.q('C2 a new item is a draft and NOT public', $$(SELECT status='draft' FROM public.bmn_spotlights) AND public.bmn_spotlight_active('search')->'items'='[]'::jsonb$$);
SELECT pgtest.t('V1 empty title rejected', $$SELECT public.bmn_spotlight_owner_save(NULL,'{"kind":"holiday","title":"   "}')$$, 'authenticated', pgtest.u(1), '22023');
SELECT pgtest.t('V2 unknown kind rejected', $$SELECT public.bmn_spotlight_owner_save(NULL,'{"kind":"weird","title":"x"}')$$, 'authenticated', pgtest.u(1), '22023');
SELECT pgtest.t('V3 javascript: link rejected', $$SELECT public.bmn_spotlight_owner_save(NULL,'{"kind":"holiday","title":"x","link_url":"javascript:alert(1)"}')$$, 'authenticated', pgtest.u(1), '22023');
SELECT pgtest.t('V4 data: link rejected', $$SELECT public.bmn_spotlight_owner_save(NULL,'{"kind":"holiday","title":"x","link_url":"data:text/html,hi"}')$$, 'authenticated', pgtest.u(1), '22023');
SELECT pgtest.t('V5 http (non-https) link rejected', $$SELECT public.bmn_spotlight_owner_save(NULL,'{"kind":"holiday","title":"x","link_url":"http://example.com"}')$$, 'authenticated', pgtest.u(1), '22023');
SELECT pgtest.t('V6 protocol-relative //host link rejected', $$SELECT public.bmn_spotlight_owner_save(NULL,'{"kind":"holiday","title":"x","link_url":"//evil.example"}')$$, 'authenticated', pgtest.u(1), '22023');
SELECT pgtest.t('V7 https link accepted', $$SELECT public.bmn_spotlight_owner_save(NULL,'{"kind":"holiday","title":"https ok","link_url":"https://example.com/a?b=1"}')$$, 'authenticated', pgtest.u(1));
SELECT pgtest.t('V8 end before start rejected', $$SELECT public.bmn_spotlight_owner_save(NULL,'{"kind":"holiday","title":"x","starts_at":"2030-01-02T00:00:00Z","ends_at":"2030-01-01T00:00:00Z"}')$$, 'authenticated', pgtest.u(1), '22023');
SELECT pgtest.t('V9 garbage date rejected with a clean error', $$SELECT public.bmn_spotlight_owner_save(NULL,'{"kind":"holiday","title":"x","starts_at":"not-a-date"}')$$, 'authenticated', pgtest.u(1), '22023');
SELECT pgtest.t('V10 unknown accent rejected', $$SELECT public.bmn_spotlight_owner_save(NULL,'{"kind":"holiday","title":"x","accent":"neon"}')$$, 'authenticated', pgtest.u(1), '22023');
SELECT pgtest.t('V11 title over 80 chars rejected', $$SELECT public.bmn_spotlight_owner_save(NULL, jsonb_build_object('kind','holiday','title',repeat('a',81)))$$, 'authenticated', pgtest.u(1), '22023');
SELECT pgtest.t('V12 priority out of range rejected', $$SELECT public.bmn_spotlight_owner_save(NULL,'{"kind":"holiday","title":"x","priority":1000}')$$, 'authenticated', pgtest.u(1), '22023');
SELECT pgtest.t('V13 non-object payload rejected', $$SELECT public.bmn_spotlight_owner_save(NULL,'[1,2]')$$, 'authenticated', pgtest.u(1), '22023');
SELECT pgtest.t('V14 invalid status via save rejected', $$SELECT public.bmn_spotlight_owner_save(NULL,'{"kind":"holiday","title":"x","status":"live"}')$$, 'authenticated', pgtest.u(1), '22023');
SELECT pgtest.t('V15 editing a missing id gives not-found', $$SELECT public.bmn_spotlight_owner_save(gen_random_uuid(),'{"title":"x"}')$$, 'authenticated', pgtest.u(1), 'P0002');
SELECT pgtest.q('V16 every rejected save left no stray rows (only the two valid items exist)', $$(SELECT count(*)=2 FROM public.bmn_spotlights)$$);

-- ---- edit semantics
SELECT pgtest.t('E1 edit keeps untouched fields, clears a nulled one', $$SELECT public.bmn_spotlight_owner_save((SELECT id FROM sp_ids WHERE k='draft'),'{"subtitle":null,"priority":5}')$$, 'authenticated', pgtest.u(1));
SELECT pgtest.q('E2 title kept, subtitle cleared, priority set', $$(SELECT title='Independence Day' AND subtitle IS NULL AND priority=5 AND link_url='/events/holiday' AND emoji='🎉' FROM public.bmn_spotlights WHERE id=(SELECT id FROM sp_ids WHERE k='draft'))$$);

-- ---- publish window
SELECT pgtest.t('P1 owner publishes', $$SELECT public.bmn_spotlight_owner_set_status((SELECT id FROM sp_ids WHERE k='draft'),'published')$$, 'authenticated', pgtest.u(1));
SELECT pgtest.q('P2 anon sees the published item', $$jsonb_array_length(public.bmn_spotlight_active('search')->'items')=1$$, 'anon');
SELECT pgtest.q('P3 signed-in user sees it too', $$jsonb_array_length(public.bmn_spotlight_active('search')->'items')=1$$, 'authenticated', pgtest.u(3));
SELECT pgtest.q('P4 public payload carries no internal fields (status, created_by, audit)', $$NOT (public.bmn_spotlight_active('search')->'items'->0 ?| ARRAY['status','created_by','updated_by','show_in_search'])$$, 'anon');
SELECT pgtest.q('P5 not shown on profiles unless show_on_profiles', $$public.bmn_spotlight_active('profile')->'items'='[]'::jsonb$$, 'anon');
SELECT pgtest.t('P6 owner turns on profile display', $$SELECT public.bmn_spotlight_owner_save((SELECT id FROM sp_ids WHERE k='draft'),'{"show_on_profiles":true}')$$, 'authenticated', pgtest.u(1));
SELECT pgtest.q('P7 now shown on profiles', $$jsonb_array_length(public.bmn_spotlight_active('profile')->'items')=1$$, 'anon');
SELECT pgtest.t('P8 owner schedules it in the future', $$SELECT public.bmn_spotlight_owner_save((SELECT id FROM sp_ids WHERE k='draft'),'{"starts_at":"2999-01-01T00:00:00Z"}')$$, 'authenticated', pgtest.u(1));
SELECT pgtest.q('P9 future item is hidden and the owner list calls it scheduled', $$public.bmn_spotlight_active('search')->'items'='[]'::jsonb AND (SELECT x->>'state' FROM jsonb_array_elements(public.bmn_spotlight_owner_list()) x WHERE x->>'id'=(SELECT id::text FROM sp_ids WHERE k='draft'))='scheduled'$$, 'authenticated', pgtest.u(1));
SELECT pgtest.t('P10 owner sets an already-ended window', $$SELECT public.bmn_spotlight_owner_save((SELECT id FROM sp_ids WHERE k='draft'),'{"starts_at":"2000-01-01T00:00:00Z","ends_at":"2000-01-02T00:00:00Z"}')$$, 'authenticated', pgtest.u(1));
SELECT pgtest.q('P11 ended item is hidden and called ended', $$public.bmn_spotlight_active('search')->'items'='[]'::jsonb AND (SELECT x->>'state' FROM jsonb_array_elements(public.bmn_spotlight_owner_list()) x WHERE x->>'id'=(SELECT id::text FROM sp_ids WHERE k='draft'))='ended'$$, 'authenticated', pgtest.u(1));
SELECT pgtest.t('P12 owner clears the window (open-ended)', $$SELECT public.bmn_spotlight_owner_save((SELECT id FROM sp_ids WHERE k='draft'),'{"starts_at":null,"ends_at":null}')$$, 'authenticated', pgtest.u(1));
SELECT pgtest.q('P13 live again', $$jsonb_array_length(public.bmn_spotlight_active('search')->'items')=1$$, 'anon');
SELECT pgtest.t('P14 pause hides it immediately', $$SELECT public.bmn_spotlight_owner_set_status((SELECT id FROM sp_ids WHERE k='draft'),'paused')$$, 'authenticated', pgtest.u(1));
SELECT pgtest.q('P15 paused is hidden', $$public.bmn_spotlight_active('search')->'items'='[]'::jsonb$$, 'anon');
SELECT pgtest.t('P16 bad status value rejected', $$SELECT public.bmn_spotlight_owner_set_status((SELECT id FROM sp_ids WHERE k='draft'),'live')$$, 'authenticated', pgtest.u(1), '22023');
SELECT pgtest.t('P17 bad surface rejected', $$SELECT public.bmn_spotlight_active('admin')$$, 'anon', NULL, '22023');

-- ---- ordering and limit
SELECT pgtest.t('R1 create 6 published items with distinct priorities', $$SELECT public.bmn_spotlight_owner_save(NULL, jsonb_build_object('kind','seasonal','title','Item '||g,'priority',g,'status','published')) FROM generate_series(1,6) g$$, 'authenticated', pgtest.u(1));
SELECT pgtest.q('R2 the feed is capped at 5 and sorted by priority, highest first', $$(SELECT jsonb_array_length(f)=5 AND (f->0->>'title')='Item 6' AND (f->4->>'title')='Item 2' FROM (SELECT public.bmn_spotlight_active('search')->'items' f) s)$$, 'anon');
SELECT pgtest.t('R3 hide-from-search flag respected', $$SELECT public.bmn_spotlight_owner_save((SELECT (x->>'id')::uuid FROM jsonb_array_elements(public.bmn_spotlight_owner_list()) x WHERE x->>'title'='Item 6'),'{"show_in_search":false}')$$, 'authenticated', pgtest.u(1));
SELECT pgtest.q('R4 hidden-from-search item is gone from the search feed', $$NOT EXISTS (SELECT 1 FROM jsonb_array_elements(public.bmn_spotlight_active('search')->'items') x WHERE x->>'title'='Item 6')$$, 'anon');

-- ---- audit and delete
SELECT pgtest.t('A1 owner deletes an item', $$SELECT public.bmn_spotlight_owner_delete((SELECT (x->>'id')::uuid FROM jsonb_array_elements(public.bmn_spotlight_owner_list()) x WHERE x->>'title'='Item 1'))$$, 'authenticated', pgtest.u(1));
SELECT pgtest.t('A2 deleting it again gives not-found', $$SELECT public.bmn_spotlight_owner_delete(gen_random_uuid())$$, 'authenticated', pgtest.u(1), 'P0002');
SELECT pgtest.q('A3 audit recorded create, edit, status, delete with the owner as actor', $$(SELECT count(*) FILTER (WHERE action='created')=8 AND count(*) FILTER (WHERE action='edited')=6 AND count(*) FILTER (WHERE action LIKE 'status_%')=2 AND count(*) FILTER (WHERE action='deleted')=1 AND bool_and(actor=pgtest.u(1)) FROM public.bmn_spotlight_audit)$$);
SELECT pgtest.q('A4 the audit row of a deleted item survives with the full old record', $$(SELECT detail->>'title'='Item 1' FROM public.bmn_spotlight_audit WHERE action='deleted')$$);
SELECT pgtest.q('A5 owner can read the audit through the function', $$jsonb_array_length(public.bmn_spotlight_owner_audit(1000))>=10$$, 'authenticated', pgtest.u(1));
SELECT pgtest.q('A6 audit limit is clamped to 200', $$jsonb_array_length(public.bmn_spotlight_owner_audit(100000))<=200$$, 'authenticated', pgtest.u(1));

-- ---- non-owner admin is NOT the owner
INSERT INTO public.bmn_admins (user_id, role) VALUES (pgtest.u(3), 'moderator') ON CONFLICT DO NOTHING;
SELECT pgtest.t('M1 a moderator (not owner) cannot manage Spotlight', $$SELECT public.bmn_spotlight_owner_list()$$, 'authenticated', pgtest.u(3), '42501');
-- leave the shared BMN tables exactly as the seed left them
DELETE FROM public.bmn_admins WHERE user_id = pgtest.u(3);
