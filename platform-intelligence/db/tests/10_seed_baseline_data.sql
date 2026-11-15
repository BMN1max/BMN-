-- Test-only: realistic rows in the EXISTING BMN tables, so the migration and rollback can be proven
-- not to alter or lose existing data. Clearly synthetic test data in a disposable database.
-- (The no-fake-data rule applies to the product; this file never runs against production.)

-- Seed as the server would (service key): the baseline's own triggers let service_role through.
SET request.jwt.claim.role = 'service_role';

INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-000000000001', 'owner@test.invalid'),
  ('00000000-0000-0000-0000-000000000002', 'user1@test.invalid'),
  ('00000000-0000-0000-0000-000000000003', 'user2@test.invalid'),
  ('00000000-0000-0000-0000-000000000004', 'user3@test.invalid');

INSERT INTO public.profiles (id, username, display_name) VALUES
  ('00000000-0000-0000-0000-000000000001', 'owner_t', 'Owner'),
  ('00000000-0000-0000-0000-000000000002', 'user1_t', 'User One'),
  ('00000000-0000-0000-0000-000000000003', 'user2_t', 'User Two'),
  ('00000000-0000-0000-0000-000000000004', 'user3_t', 'User Three');

INSERT INTO public.bmn_admins (user_id, role) VALUES ('00000000-0000-0000-0000-000000000001', 'owner');

INSERT INTO public.posts (id, user_id, title, caption, status) VALUES
  ('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-000000000002', 'Post one', 'caption one', 'published'),
  ('00000000-0000-0000-0000-0000000a0002', '00000000-0000-0000-0000-000000000003', 'Post two', 'caption two', 'published'),
  ('00000000-0000-0000-0000-0000000a0003', '00000000-0000-0000-0000-000000000004', 'Post three', 'caption three', 'published');

INSERT INTO public.comments (user_id, post_id, body, content) VALUES
  ('00000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000a0001', 'nice', 'nice'),
  ('00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000a0002', 'thanks', 'thanks');

INSERT INTO public.follows (follower_id, following_id) VALUES
  ('00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000003'),
  ('00000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000002');

INSERT INTO public.likes (user_id, post_id) VALUES
  ('00000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000a0001');

INSERT INTO public.messages (sender_id, recipient_id, content) VALUES
  ('00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000003', 'hello');

INSERT INTO public.content_reports (reporter_id, post_id, reported_user_id, reason, details) VALUES
  ('00000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-000000000002', 'spam', 'test report');

INSERT INTO public.bmn_verification_requests (user_id, request_reason) VALUES
  ('00000000-0000-0000-0000-000000000002', 'I am a creator and want a verified badge on my account.');
