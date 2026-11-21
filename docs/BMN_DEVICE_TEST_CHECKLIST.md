# BMN — Real-device checklist (Batch 3)

These are the checks I **could not** run (no iPhone, Safari or Android phone in my sandbox). Do them after uploading the files. Each takes under a minute. Tick or note what you see.

## A. Nothing broke (do this first, on iPhone Safari and on an Android phone)

- [ ] https://bmnng.vercel.app opens, the feed shows, videos play.
- [ ] Sign in, open Discover, open Profile, open Inbox, open Create. No blank screens.
- [ ] Pull down the page / scroll the feed for 30 seconds. Note whether it feels smoother, the same or worse than before.

## B. Performance governor (`bmn-perf.js`)

Open each address, use the app for about 30 seconds, and compare how scrolling feels:

1. `https://bmnng.vercel.app/?perf=full` — everything on, governor never steps down.
2. `https://bmnng.vercel.app/?perf=saver` — blur replaced by solid panels. Check the text is still easy to read, in dark and light mode.
3. `https://bmnng.vercel.app/?perf=auto` — the default. Leave it 20 seconds while scrolling.

To see what it decided, open the browser console (desktop) and type `BMN_PERF.stats()`. On a phone you can check the page's `<html>` attribute `data-bmn-perf` (0, 1 or 2) through Safari Web Inspector from a Mac, or simply judge by eye: level 1 removes the moving background; level 2 also removes the blur.

- [ ] Which address felt best on iPhone?
- [ ] Which address felt best on Android?
- [ ] Does `?perf=saver` look acceptable (not broken, not unreadable)?

Remember: the choice sticks on that phone. Open `?perf=auto` to return to normal.

## C. Owner tools (only you, signed in as the owner)

- [ ] Profile → you see **Intelligence** and **Spotlight** buttons next to your profile actions. A normal account must show **neither**.
- [ ] Tap **Intelligence**: the full-screen console opens (this was invisible before this batch's fix). **Close** works. On a keyboard, Escape closes it.
- [ ] Tap **Spotlight**. Before the Spotlight database migration is applied you should see: "Spotlight is not installed in the database yet…". That is correct.

## D. After you approve and apply the Spotlight migration (README step 6)

- [ ] Profile → Spotlight → **New Spotlight**, fill a title only, **Save**. It says it is a *draft*. Check Discover on another account: nothing appears.
- [ ] **Publish**. Your own Discover updates at once. Other users see it the next time they open the app, or within about 10 minutes if they already have it open.
- [ ] Set a countdown date in the future: the countdown ticks every second (it is calculated from the server clock, not the phone clock; this one is not covered by my tests, so please try changing the phone time to confirm).
- [ ] Add a link starting with `https://` and button text. The button opens the link in a new tab. A link not starting with `https://` or `/` is refused by the form.
- [ ] **Pause** removes the card; **Delete** asks first.
- [ ] Audit log lists every create / edit / publish / delete.

## E. Report back

Send me the answers to the unchecked boxes, plus phone model and OS version. That drives Phase 4 (see the audit report).
