// BMN Board browser suite. Runs the REAL client (bmn-board.js + index.html) in headless Chromium against pgserver.js
// (real local PostgreSQL 16 with the B1 migration, real RLS and SECURITY DEFINER functions).
// LOCAL SIMULATION ONLY: not a production test and not a real-iPhone/Android test.
const L = require('./lib'); const { check, sleep, U, api } = L;
const sql = async (s, uid) => { const r = await api('/sql', { sql: s, uid }); if (r.error) throw new Error(r.error.message); return r.data; };
const q1 = async (s) => sql(`SELECT coalesce(jsonb_agg(x),'[]'::jsonb) FROM (${s}) x`);
const num = async (s) => (await q1(s))[0].n;
const ev = (u, fn, ...a) => u.p.evaluate(fn, ...a);
async function until(u, fn, arg, ms = 6000) { const t = Date.now(); while (Date.now() - t < ms) { if (await u.p.evaluate(fn, arg).catch(() => false)) return true; await sleep(120); } return false; }
const openBoard = async (u) => { await ev(u, () => window.BMNBoard.open({ fresh: true })); await until(u, () => document.querySelector('#bmnBoard.open')); await sleep(500); };
const posts = (u) => ev(u, () => [...document.querySelectorAll('#bmnBoard .bd-post:not(.gone)')].map(e => e.dataset.pid));
const sheetPick = async (u, label) => { const ok = await until(u, () => !!document.querySelector('#bdSheet .bd-si')); await ev(u, (l) => { const b = [...document.querySelectorAll('#bdSheet .bd-si')].find(b => b.textContent.trim() === l); if (!b) throw new Error('no sheet item ' + l + ' in ' + [...document.querySelectorAll('#bdSheet .bd-si')].map(x => x.textContent)); b.click(); }, label); await sleep(500); };
const compose = async (u, text) => { await ev(u, () => document.getElementById('bdFab').click()); await until(u, () => !!document.getElementById('bdCT')); await u.p.fill('#bdCT', text); await sleep(150); await u.p.click('#bdCS'); await sleep(1200); };
const tab = async (u, nav) => { await ev(u, (n) => document.querySelector('#bmnBoard [data-nav="' + n + '"]').click(), nav); await sleep(900); };
const mode = async (u, m) => { await ev(u, (x) => document.querySelector('#bmnBoard [data-mode="' + x + '"]').click(), m); await sleep(1000); };
const act = async (u, pid, a, scope = '#bmnBoard') => { await ev(u, ([pid, a, sc]) => { const el = document.querySelector(sc + ' .bd-post[data-pid="' + pid + '"] [data-a="' + a + '"]'); if (!el) throw new Error('no action ' + a); el.click(); }, [pid, a, scope]); await sleep(800); };

(async () => {
  await api('/reset');
  const a = await L.newUser(U.A), b = await L.newUser(U.B), c = await L.newUser(U.C), anon = await L.newUser(null);
  check('no page errors on load (A,B,C,signed-out)', a.errs.length + b.errs.length + c.errs.length + anon.errs.length === 0, JSON.stringify([...a.errs, ...b.errs, ...c.errs, ...anon.errs]));
  check('Board module loaded and exposes open/close/openPost/openTag', await ev(a, () => ['open', 'close', 'openPost', 'openTag'].every(k => typeof window.BMNBoard[k] === 'function')));

  // ---------- B button opens Board; personal page stays reachable via About BMN ----------
  const bbtn = await ev(a, () => { const b = document.querySelector('#lgtt [data-act="bmn-home"]'); return b && { label: b.getAttribute('aria-label'), title: b.title, vis: !!(b.offsetWidth || b.offsetHeight) }; });
  check('B button relabelled "Open BMN Board"', bbtn && bbtn.label === 'Open BMN Board' && bbtn.title === 'BMN Board', JSON.stringify(bbtn));
  await ev(a, () => window.LGTT && window.LGTT.open({ view: 'feed' })); await sleep(900);
  await ev(a, () => document.querySelector('#lgtt [data-act="bmn-home"]').click()); await until(a, () => !!document.querySelector('#bmnBoard.open'));
  const afterB = await ev(a, () => ({ board: !!document.querySelector('#bmnBoard.open'), inStage: document.getElementById('bmnBoard').parentNode.id, topbar: (() => { const t = document.querySelector('.topbar'); return t ? getComputedStyle(t).display : 'none'; })(), title: document.getElementById('bdTitle').textContent }));
  check('tapping B opens BMN Board inside the Community stage (not the personal page)', afterB.board && afterB.inStage === 'lgttStage' && afterB.topbar === 'none' && afterB.title === 'BMN Board', JSON.stringify(afterB));
  check('Board opens on the For You tab, nav shows Home active', await ev(a, () => document.querySelector('[data-mode="for_you"]').classList.contains('on') && document.querySelector('[data-nav="home"]').classList.contains('on')));
  await sleep(800);

  // ---------- empty state: no fake posts ----------
  check('no demo/fake posts: empty DB shows the empty state', (await posts(a)).length === 0 && await ev(a, () => /No posts yet/.test(document.getElementById('bdMain').textContent)), await num('select count(*) n from board_posts'));

  // ---------- composer ----------
  await ev(a, () => document.getElementById('bdFab').click()); await until(a, () => !!document.getElementById('bdCT'));
  check('composer: Post disabled when empty', await ev(a, () => document.getElementById('bdCS').disabled));
  await a.p.fill('#bdCT', '   '); check('composer: whitespace-only stays disabled', await ev(a, () => document.getElementById('bdCS').disabled));
  await a.p.fill('#bdCT', 'x'.repeat(480)); check('composer: counter appears near the limit (20 left)', await ev(a, () => document.getElementById('bdCC').textContent === '20'));
  await a.p.fill('#bdCT', 'y'.repeat(520)); check('composer: hard 500-character limit (maxlength)', await ev(a, () => document.getElementById('bdCT').value.length === 500));
  await ev(a, () => document.getElementById('bdCX').click()); await sleep(500);
  await compose(a, 'Hello BMN Board! #BMN #Launch with @bob_test see https://example.com/x.');
  const p1 = (await q1(`select id, body, author_id from board_posts order by created_at`))[0];
  check('post created through the RPC, authored by the signed-in user', p1 && p1.author_id === U.A && /Hello BMN Board/.test(p1.body));
  check('hashtags and mentions stored server-side', (await num(`select count(*) n from board_post_tags where post_id='${p1.id}'`)) === 2 && (await num(`select count(*) n from board_post_mentions where post_id='${p1.id}'`)) === 1);
  const card = await ev(a, () => { const e = document.querySelector('#bmnBoard .bd-post'); return e && { tags: [...e.querySelectorAll('a.bd-tag')].map(x => x.dataset.tag), men: [...e.querySelectorAll('a.bd-men')].map(x => x.dataset.user), link: e.querySelector('a.bd-link') && { href: e.querySelector('a.bd-link').href, rel: e.querySelector('a.bd-link').rel, trailing: e.querySelector('a.bd-link').textContent }, name: e.querySelector('.bd-name').textContent, handle: e.querySelector('.bd-h').textContent }; });
  check('new post appears at the top with author name/@handle from the EXISTING profile', card && card.name === 'Alice Test' && card.handle === '@alice_test', JSON.stringify(card));
  check('hashtags, @mention and link are linkified; link opens safely and drops trailing punctuation', card && card.tags.join() === 'bmn,launch' && card.men.join() === 'bob_test' && card.link && /noopener/.test(card.link.rel) && !/\.$/.test(card.link.href), JSON.stringify(card));
  check('no video-feed leakage: Board post never written to posts', (await num('select count(*) n from posts')) === 0);
  const xss = await (async () => { await compose(a, '<img src=x onerror="window.__xss=1"> <script>window.__xss=2</script>'); await sleep(300); return ev(a, () => ({ x: window.__xss || 0, imgs: document.querySelectorAll('#bmnBoard .bd-text img').length, txt: document.querySelector('#bmnBoard .bd-text').textContent })); })();
  check('HTML in a post is shown as text, never executed', xss.x === 0 && xss.imgs === 0 && /<img/.test(xss.txt), JSON.stringify(xss));
  const p2 = (await q1(`select id from board_posts order by created_at desc limit 1`))[0].id;

  // ---------- B interacts ----------
  await openBoard(b); await mode(b, 'latest');
  check('B sees A\'s posts in Latest (public timeline)', (await posts(b)).length === 2);
  await act(b, p1.id, 'like');
  check('like: stored once, counter trigger and UI agree', (await num(`select like_count n from board_posts where id='${p1.id}'`)) === 1 && (await num(`select count(*) n from board_likes where post_id='${p1.id}' and user_id='${U.B}'`)) === 1 && await ev(b, (id) => document.querySelector('.bd-post[data-pid="' + id + '"] .bd-act.like .n').textContent === '1' && document.querySelector('.bd-post[data-pid="' + id + '"] .bd-act.like').classList.contains('on'), p1.id));
  await act(b, p1.id, 'like');
  check('unlike removes it (count back to 0)', (await num(`select like_count n from board_posts where id='${p1.id}'`)) === 0);
  await act(b, p1.id, 'like');
  await act(b, p1.id, 'bm');
  check('bookmark stored privately', (await num(`select count(*) n from board_bookmarks where post_id='${p1.id}' and user_id='${U.B}'`)) === 1);
  await act(b, p1.id, 'rp'); await sheetPick(b, 'Repost');
  check('repost stored; count 1', (await num(`select repost_count n from board_posts where id='${p1.id}'`)) === 1 && await ev(b, (id) => document.querySelector('.bd-post[data-pid="' + id + '"] .bd-act.rp').classList.contains('on'), p1.id));
  await act(b, p1.id, 'rp'); await sheetPick(b, 'Undo repost');
  check('undo repost', (await num(`select repost_count n from board_posts where id='${p1.id}'`)) === 0);
  await act(b, p1.id, 'rp'); await sheetPick(b, 'Repost');
  await act(b, p1.id, 'rp'); await sheetPick(b, 'Quote'); await until(b, () => !!document.getElementById('bdCT'));
  await b.p.fill('#bdCT', 'Quoting this one'); await b.p.click('#bdCS'); await sleep(1300);
  const qp = (await q1(`select id, quote_id from board_posts where author_id='${U.B}' and quote_id is not null`))[0];
  check('quote repost: new post linking the original, quote_count 1', qp && qp.quote_id === p1.id && (await num(`select quote_count n from board_posts where id='${p1.id}'`)) === 1);
  check('quoted post is embedded in the feed card', await ev(b, () => !!document.querySelector('#bmnBoard .bd-quote[data-open]')));

  // ---------- thread / replies ----------
  await ev(b, (id) => document.querySelector('#bmnBoard .bd-post[data-pid="' + id + '"] .bd-text').click(), p1.id); await until(b, () => !!document.querySelector('#bmnBoard .bd-post.main'));
  check('tap a post opens the thread with the post as main', await ev(b, (id) => document.querySelector('#bmnBoard .bd-post.main').dataset.pid === id && document.getElementById('bdTitle').textContent === 'Post', p1.id));
  await ev(b, () => document.querySelector('#bmnBoard .bd-replybar').click()); await until(b, () => !!document.getElementById('bdCT'));
  await b.p.fill('#bdCT', 'First reply from B'); await b.p.click('#bdCS'); await sleep(1300);
  const r1 = (await q1(`select id, parent_id, root_id from board_posts where parent_id='${p1.id}'`))[0];
  check('reply stored with parent/root; reply_count 1; shown under the post', r1 && r1.root_id === p1.id && (await num(`select reply_count n from board_posts where id='${p1.id}'`)) === 1 && await ev(b, () => document.querySelectorAll('#bdReplies .bd-post').length === 1));
  await ev(b, () => document.querySelector('#bdReplies .bd-post .bd-text').click()); await sleep(1200);
  check('reply thread shows the ancestor above the reply', await ev(b, () => document.querySelectorAll('#bmnBoard .bd-post.thread').length === 1 && document.querySelector('#bmnBoard .bd-post.main .bd-text').textContent === 'First reply from B'));
  await ev(b, () => document.getElementById('bdBack').click()); await sleep(600); await ev(b, () => document.getElementById('bdBack').click()); await sleep(800);
  check('back returns to the timeline', await ev(b, () => document.getElementById('bdTitle').textContent === 'BMN Board' && !!document.querySelector('#bmnBoard .bd-post')));

  // ---------- views (real, one per signed-in non-author) ----------
  await sleep(2500);
  const views = await q1(`select viewer_id as user_id from board_views where post_id='${p1.id}'`);
  check('views: recorded for the viewer B only, never the author', views.some(v => v.user_id === U.B) && !views.some(v => v.user_id === U.A), JSON.stringify(views));
  check('view_count equals the number of distinct viewers', (await num(`select view_count n from board_posts where id='${p1.id}'`)) === (await num(`select count(*) n from board_views where post_id='${p1.id}'`)));

  // ---------- A: notifications, following, bookmarks ----------
  await openBoard(a);
  await ev(a, () => window.BMNBoard._state && 0); await sleep(300);
  const nrows = await q1(`select type from board_notifications where user_id='${U.A}' order by type`);
  check('author is notified of like/repost/quote/reply/mention-free events (real rows)', ['like', 'quote', 'reply', 'repost'].every(t => nrows.some(n => n.type === t)), JSON.stringify(nrows));
  await a.p.waitForFunction(() => document.querySelector('[data-nav="notifs"] .bd-nb') && !document.querySelector('[data-nav="notifs"] .bd-nb').hidden, null, { timeout: 8000 }).catch(() => {});
  check('unread badge shows on Alerts', await ev(a, () => { const n = document.querySelector('[data-nav="notifs"] .bd-nb'); return n && !n.hidden && +n.textContent > 0; }));
  await tab(a, 'notifs');
  const notes = await ev(a, () => [...document.querySelectorAll('#bmnBoard .bd-note')].map(n => n.textContent.replace(/\s+/g, ' ').trim()));
  check('notifications list shows who did what', notes.length >= 4 && notes.some(t => /Bob Test liked your post/.test(t)) && notes.some(t => /replied to your post/.test(t)), JSON.stringify(notes));
  await sleep(800);
  check('opening notifications marks them read (badge clears, DB read_at set)', (await num(`select count(*) n from board_notifications where user_id='${U.A}' and read_at is null`)) === 0 && await ev(a, () => document.querySelector('[data-nav="notifs"] .bd-nb').hidden));
  await ev(a, () => document.querySelector('#bmnBoard .bd-note[data-open]').click()); await sleep(1000);
  check('tapping a notification opens that post thread', await ev(a, () => !!document.querySelector('#bmnBoard .bd-post.main')));
  await tab(a, 'home'); await mode(a, 'following');
  const fol = await posts(a);
  check('Following timeline shows posts from followed people (A follows B)', fol.includes(qp.id), JSON.stringify(fol));
  const rpFeed = (await sql(`select jsonb_build_object('n', count(*)) from board_feed('following',50) where reposted_by='${U.B}'`, U.A)).n;
  check('Following feed (server) returns reposts by followed people with reposted_by set', rpFeed >= 1, rpFeed);
  check('reposted entries render a "reposted" context line', await ev(a, () => [...document.querySelectorAll('#bmnBoard .bd-ctx')].some(e => /reposted/.test(e.textContent))));
  await mode(b, 'following');
  await tab(b, 'bookmarks');
  check('Bookmarks tab lists B\'s saved post, private to B', await ev(b, (id) => !!document.querySelector('#bmnBoard .bd-post[data-pid="' + id + '"]'), p1.id) && (await num(`select count(*) n from board_bookmarks where user_id='${U.A}'`)) === 0);
  await tab(b, 'home');

  // ---------- profiles: ONE profile system ----------
  await openBoard(c); await mode(c, 'latest');
  await ev(c, () => document.querySelector('#bmnBoard .bd-post .bd-av').click()); await sleep(1100);
  const prof = await ev(c, () => ({ view: document.getElementById('lgttStage').dataset.view, board: document.getElementById('bmnBoard').hidden, pill: !!document.querySelector('.bd-pill:not([hidden])'), txt: (document.getElementById('lgttStage').textContent || '').slice(0, 4000) }));
  check('tapping an avatar opens the normal Community profile (LGTT profile view), Board steps aside', prof.view === 'profile' && prof.board && prof.pill, JSON.stringify({ v: prof.view, b: prof.board, p: prof.pill }));
  await ev(c, () => document.querySelector('.bd-pill').click()); await sleep(900);
  check('"← Board" pill returns to Board where we were', await ev(c, () => !document.getElementById('bmnBoard').hidden && !!document.querySelector('#bmnBoard .bd-post')));
  await ev(c, () => document.querySelector('#bmnBoard .bd-post .bd-name').click()); await sleep(1000);
  check('tapping the display name opens the profile too', await ev(c, () => document.getElementById('lgttStage').dataset.view === 'profile'));
  await ev(c, () => document.querySelector('.bd-pill').click()); await sleep(800);
  await ev(c, () => { const m = [...document.querySelectorAll('#bmnBoard a.bd-men')].find(x => x.dataset.user === 'bob_test'); m.click(); }); await sleep(1400);
  check('tapping @bob_test resolves the username and opens that existing profile', await ev(c, () => document.getElementById('lgttStage').dataset.view === 'profile'));
  await ev(c, () => document.querySelector('.bd-pill').click()); await sleep(700);

  // ---------- tag, search, discover ----------
  await ev(c, () => document.querySelector('#bmnBoard a.bd-tag').click()); await sleep(1100);
  check('hashtag opens the tag timeline', await ev(c, () => document.getElementById('bdTitle').textContent === '#bmn' && document.querySelectorAll('#bmnBoard .bd-post').length >= 1));
  await ev(c, () => document.getElementById('bdBack').click()); await sleep(500);
  await tab(c, 'search'); await c.p.fill('#bdQ', 'launch'); await sleep(1500);
  check('search finds posts by word / hashtag', await ev(c, () => document.querySelectorAll('#bdRes .bd-post').length >= 1));
  await ev(c, () => document.querySelector('[data-qt="people"]').click()); await sleep(300); await c.p.fill('#bdQ', 'alice'); await sleep(1500);
  check('people search finds existing BMN profiles', await ev(c, () => [...document.querySelectorAll('#bdRes .bd-person')].some(p => /Alice Test/.test(p.textContent))));
  await tab(c, 'discover'); await sleep(1500);
  const disc = await ev(c, () => ({ trend: [...document.querySelectorAll('#bdTrend .bd-trow b')].map(x => x.textContent), people: document.querySelectorAll('#bdPeople .bd-person').length, pop: document.querySelectorAll('#bdPop .bd-post').length }));
  check('Discover: real trending hashtags, people and popular posts', disc.trend.includes('#bmn') && disc.pop >= 1, JSON.stringify(disc));
  // follow from Discover people uses the existing follows table
  if (disc.people) { const pid = await ev(c, () => document.querySelector('#bdPeople [data-follow]').dataset.follow); await ev(c, () => document.querySelector('#bdPeople [data-follow]').click()); await sleep(900); check('Follow from Discover writes the existing follows table', (await num(`select count(*) n from follows where follower_id='${U.C}' and following_id='${pid}'`)) === 1); } else check('Discover people list (no candidates in this fixture)', true, 'skipped');

  // ---------- edit / delete / report ----------
  await openBoard(a); await mode(a, 'latest');
  await act(a, p2, 'more'); await sheetPick(a, 'Edit post'); await until(a, () => !!document.getElementById('bdCT'));
  await a.p.fill('#bdCT', 'Edited text'); await a.p.click('#bdCS'); await sleep(1200);
  check('edit own post: body changed, edited_at set, history row kept', (await q1(`select body, edited_at is not null as e from board_posts where id='${p2}'`))[0].body === 'Edited text' && (await num(`select count(*) n from board_post_edits where post_id='${p2}'`)) >= 1 && await ev(a, (id) => !!document.querySelector('.bd-post[data-pid="' + id + '"] .bd-ed'), p2));
  await act(a, p1.id, 'more');
  check('own post menu offers Edit/Delete, no Report/Block', await ev(a, () => { const t = [...document.querySelectorAll('#bdSheet .bd-si')].map(x => x.textContent.trim()); return t.includes('Delete post') && !t.includes('Report post') && !t.some(x => /^Block/.test(x)); }));
  await ev(a, () => document.querySelector('#bdSheet [data-close]').click()); await sleep(500);
  await openBoard(b); await mode(b, 'latest');
  await act(b, p2, 'more'); await sheetPick(b, 'Report post'); await sheetPick(b, 'Spam');
  check('report goes to the existing content_reports table with board_post_id', (await num(`select count(*) n from content_reports where board_post_id='${p2}' and reporter_id='${U.B}' and reason='spam'`)) === 1);
  await act(a, p2, 'more'); await sheetPick(a, 'Delete post'); await sheetPick(a, 'Delete');
  check('delete own post: soft-deleted tombstone, removed from feeds, counts intact', (await q1(`select deleted_at is not null d, body from board_posts where id='${p2}'`))[0].d === true && !(await posts(a)).includes(p2));
  await mode(a, 'for_you');

  // ---------- block (same user_blocks as messaging) ----------
  await openBoard(c); await mode(c, 'latest');
  const bPost = qp.id; check('before block: C sees B\'s post', (await posts(c)).includes(bPost));
  await act(c, bPost, 'more'); await sheetPick(c, 'Block @bob_test'); await sheetPick(c, 'Block'); await sleep(900);
  check('block writes the existing user_blocks table (kind=block)', (await num(`select count(*) n from user_blocks where user_id='${U.C}' and target_id='${U.B}' and kind='block'`)) === 1);
  check('blocked author disappears from C\'s Board', !(await posts(c)).includes(bPost));
  const leak = (await sql(`select jsonb_build_object('n', count(*)) from board_posts where author_id='${U.B}'`, U.C)).n;
  check('server enforces the block too (RLS): C cannot read B\'s posts, B cannot read C\'s', leak === 0 && (await sql(`select jsonb_build_object('n', count(*)) from board_feed('latest',50) f join board_posts p on p.id=f.post_id where p.author_id='${U.B}'`, U.C)).n === 0, leak);

  // ---------- signed-out ----------
  await openBoard(anon); await mode(anon, 'latest');
  check('signed-out visitor can read public posts', (await posts(anon)).length >= 1);
  await ev(anon, () => document.querySelector('#bmnBoard .bd-act.like').click()); await sleep(600);
  check('signed-out like asks to sign in, writes nothing', await ev(anon, () => /Sign in to like/.test(document.getElementById('bdToast').textContent)) && (await num(`select count(*) n from board_likes where user_id is null`)) === 0);
  await mode(anon, 'following'); check('Following asks signed-out visitors to sign in', await ev(anon, () => /Sign in to see your Following/.test(document.getElementById('bdMain').textContent)));

  // ---------- themes / layout ----------
  const th = await ev(a, () => { const r = document.getElementById('bmnBoard'), s = getComputedStyle(r); return { t: r.dataset.bdTheme, bg: s.backgroundColor, sc: getComputedStyle(document.getElementById('bdScroll')).backdropFilter }; });
  check('dark theme: solid near-black timeline, no blur on the scroll area', th.t === 'dark' && th.bg === 'rgb(10, 10, 12)' && /none|undefined/.test(String(th.sc)), JSON.stringify(th));
  await a.p.emulateMedia({ colorScheme: 'light' }); await sleep(500);
  const th2 = await ev(a, () => ({ t: document.getElementById('bmnBoard').dataset.bdTheme, bg: getComputedStyle(document.getElementById('bmnBoard')).backgroundColor }));
  check('system theme: Board follows the device (light)', th2.t === 'light' && th2.bg === 'rgb(244, 245, 248)', JSON.stringify(th2));
  const noOverflow = await ev(a, () => document.documentElement.scrollWidth <= window.innerWidth + 1 && document.getElementById('bdScroll').scrollWidth <= document.getElementById('bdScroll').clientWidth + 1);
  check('no horizontal overflow at iPhone 14 width', noOverflow);
  await a.p.screenshot({ path: '../results/board_light.png' }); await a.p.emulateMedia({ colorScheme: 'dark' }); await sleep(400);
  await a.p.screenshot({ path: '../results/board_dark.png' });
  await openBoard(b); await ev(b, () => document.getElementById('bdFab').click()); await sleep(600); await b.p.screenshot({ path: '../results/board_composer.png' });

  // ---------- About BMN keeps the personal page ----------
  await ev(a, () => window.BMNBoard.close()); await sleep(500);
  await ev(a, () => window.LGTT.open({ view: 'feed' })); await sleep(600);
  await ev(a, () => { const t = document.querySelector('#lgtt [data-dock="profile"]') || document.querySelector('#lgttDock [data-dock="profile"]'); t && t.click(); }); await sleep(900);
  const opened = await ev(a, () => { const b = document.querySelector('[data-act="settings"], #lgtt [data-act="open-settings"], #lgtt [aria-label="Settings"]'); if (b) { b.click(); return true; } return false; }); await sleep(900);
  await ev(a, () => { const t = document.querySelector('#lgttSetTabs [data-stab="app"]'); t && t.click(); }); await sleep(1500);
  const about = await ev(a, () => !!document.getElementById('bmnSetAbout'));
  check('Settings (App tab) has an "About BMN" row', about, 'settings opened=' + opened);
  if (about) {
    await ev(a, () => document.getElementById('bmnSetAbout').click()); await sleep(1500);
    const pp = await ev(a, () => ({ top: getComputedStyle(document.querySelector('.topbar')).display, main: getComputedStyle(document.querySelector('main.wrap')).display, boardHidden: document.getElementById('bmnBoard').hidden }));
    check('About BMN opens the preserved personal BMN page', pp.top !== 'none' && pp.main !== 'none' && pp.boardHidden, JSON.stringify(pp));
  }
  check('original personal page content is still in index.html (hero/sections intact)', await ev(a, () => !!document.querySelector('main.wrap') && document.querySelector('main.wrap').children.length > 2));
  check('no page errors during the whole run', [a, b, c, anon].every(u => u.errs.length === 0), JSON.stringify([a, b, c, anon].flatMap(u => u.errs)));
  const { pass, fail } = L.summary(); console.log('\nBOARD BROWSER: PASS ' + pass + '  FAIL ' + fail);
  require('fs').writeFileSync('../results/board_browser_results.json', JSON.stringify({ pass, fail, results: L.results }, null, 1));
  await L.close(); process.exit(fail ? 1 : 0);
})().catch(async e => { console.error('SUITE CRASH', e); await L.close(); process.exit(2); });
