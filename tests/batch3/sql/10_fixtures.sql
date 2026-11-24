-- six users: 1 alice, 2 bob, 3 carol, 4 dave, 5 erin, 6 mallory (outsider)
INSERT INTO auth.users (id, email) SELECT t.u(n), 'u' || n || '@test.local' FROM generate_series(1,6) n ON CONFLICT DO NOTHING;
INSERT INTO public.profiles (id, username, display_name, last_seen_at)
SELECT t.u(n), (ARRAY['alice','bob','carol','dave','erin','mallory'])[n], initcap((ARRAY['alice','bob','carol','dave','erin','mallory'])[n]), now()
FROM generate_series(1,6) n ON CONFLICT (id) DO NOTHING;
GRANT ALL ON ALL TABLES IN SCHEMA public TO anon, authenticated, service_role;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO anon, authenticated, service_role;
