# Optional BMN Community backend

Node.js 20+ Express and Socket.IO service. This is a separate backend; it cannot execute inside the Vercel-hosted `index.html`.

Install dependencies with `npm install`, run tests with `npm test`, and start with `npm start`. Copy `.env.example` to `.env` on the server and fill the required Supabase server-only credentials. Never commit `.env`.

The current frontend continues using Supabase Storage and Supabase messages unless you explicitly deploy/configure and connect the optional API. AWS S3 upload, Redis, HLS and Stripe are not automatically active.
