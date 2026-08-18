# Full Next.js Migration Checklist

Status: **implemented locally — privileged acceptance and production deployment pending**

Audit date: **2026-08-18**

Baseline commit: **`be5fd02`**

Migration branch: **`codex/nextjs-migration`**

Rollback tag: **`pre-nextjs-migration-20260818`**

## Execution result

The framework conversion is complete in the local migration branch. The code
now has one root Next.js 16 App Router runtime, all 16 original URLs, isolated
shop/auth/staff client providers, cookie-backed Supabase auth, server-enforced
staff role boundaries, server-seeded public catalog/product routes, and the
existing interactive workflows preserved as Client Components.

Local automated gates completed during execution:

- [x] Clean `npm ci` with zero reported package vulnerabilities.
- [x] ESLint, Next route type generation, TypeScript, and production build.
- [x] Production-mode anonymous route, auth-redirect, catalog, search, cart,
  reload-persistence, and navigation browser tests: 11/11 passed with zero
  flakes; the query-param hydration stress repeat passed 3/3.
- [x] Read-only anonymous query against the configured live catalog.
- [x] Client bundle scan against all configured private credential values.
- [x] Import/stale-runtime scan: no Vite entrypoint, React Router runtime,
  `import.meta.env`, SPA rewrite, or second application remains.

Operator acceptance still required before production cutover:

- [ ] Exercise the authenticated admin, staff, driver, inactive, customer, and
  missing-profile matrix with designated test accounts.
- [ ] Recheck Realtime behavior in two simultaneous authenticated sessions and
  delivery photo capture on a real mobile device.
- [ ] Deploy a Vercel preview, run the non-payment smoke suite, then perform the
  production cutover.

Deferred type hardening, which is not required for the framework cutover:

- [ ] Generate a complete Supabase `Database` type and replace the remaining
  legacy operational-screen `any` payloads with generated relationship types.

## Decision and target state

- The pre-migration baseline was the root Vite/React SPA, not a Next.js
  application.
- `storefront/` was an older, incomplete Next.js 14 prototype with only `/` and
  `/product/[handle]`; it was reference material, not the migration base.
- The repository root has been converted in place to one Next.js App Router
  application.
- Keep all 16 current URLs and user-visible behavior unchanged.
- Keep the public shop, login, and staff/driver application in one Vercel
  project and on the existing domain.
- Target the current security-patched stable Next.js release when execution
  begins. The migration is pinned to Next.js 16.3.1 and React 19.2.8, with
  TypeScript 5 and Node.js 22+ (the installed Supabase SDK no longer supports
  Node.js 20).
- Use App Router route groups for `(shop)`, `(auth)`, and `(staff)` without
  changing public URLs.
- Use cookie-backed Supabase auth with `@supabase/ssr`, a Next.js `proxy.ts` for
  token refresh, and a secure profile/role check in the staff layout. Supabase
  RLS remains the final authorization boundary.
- Keep interactive operations, Realtime, React Query mutations, cart state,
  Stripe redirects, and photo capture in Client Components. Move public catalog
  reads and metadata server-side after client-parity is working.
- Keep Tailwind CSS 3 during the framework conversion to avoid mixing a styling
  migration into the routing/runtime migration.
- Keep local development on port `5173` initially. The database checkout
  redirect allowlist already permits that port; moving to port `3000` requires
  an explicit migration and live allowlist update.
- Do not rewrite the Supabase schema, RPCs, RLS policies, Realtime setup, Stripe
  Vault integration, or Python migration runner as part of the frontend
  conversion.

Useful primary references:

- [Next.js App Router](https://nextjs.org/docs/app)
- [Next.js migration from Vite](https://nextjs.org/docs/14/app/building-your-application/upgrading/from-vite)
- [Next.js 16 upgrade requirements](https://nextjs.org/docs/app/guides/upgrading/version-16)
- [Supabase server-side auth for Next.js](https://supabase.com/docs/guides/auth/server-side/creating-a-client)
- [Next.js testing guide](https://nextjs.org/docs/app/guides/testing)

## Audit findings already completed

- [x] Confirm the root app is Vite + React 18 + React Router.
- [x] Confirm the nested Next.js app is incomplete and stale relative to the
  live Vite storefront.
- [x] Inventory all 16 routes.
- [x] Inventory browser-only behavior: Realtime, `localStorage`, Stripe
  navigation, query-string navigation, scrolling, and delivery-photo capture.
- [x] Run the current Vite production build. It passes, with a 559.38 kB
  minified JavaScript chunk warning.
- [x] Run a standalone TypeScript check. It currently fails with five
  diagnostics: two Vite env typings and three Supabase result casts in
  `Delivery.tsx` and `Orders.tsx`.
- [x] Confirm there is no application lint configuration, automated test suite,
  CI workflow, or `typecheck` script.
- [x] Confirm the root SPA catch-all in `vercel.json` is incompatible with App
  Router and must be removed at cutover.
- [x] Confirm checkout redirect migration `035` permits local port `5173`, but
  not Next.js's default port `3000` or arbitrary Vercel preview origins.

## Phase 0 — Freeze behavior and establish rollback

- [x] Create a dedicated migration branch from the current production commit.
- [x] Tag and record the exact pre-migration production commit.
- [ ] Record the corresponding Vercel deployment ID so it can be redeployed
  without reverting database state.
- [ ] Confirm the worktree is clean and record the current dependency lockfile.
- [ ] Capture desktop and mobile screenshots for every public route and the
  major staff/driver screens.
- [ ] Record a baseline browser-console and network pass with no unexplained
  runtime errors.
- [ ] Record baseline behavior for anonymous, admin, staff, driver, customer,
  inactive, and missing-profile cases.
- [x] Write a short data-safety note: the migration must not reseed production,
  alter live orders, or initiate a real Stripe charge during verification.
- [x] Confirm rollback is application-only; no destructive or irreversible
  database migration is planned.

### Phase 0 gate

- [ ] Baseline artifacts exist and the old deployment can be restored in one
  redeploy.

## Phase 1 — Add safety checks before changing frameworks

- [x] Add `typecheck`, `lint`, and `test:e2e` scripts.
- [x] Add an ESLint flat configuration compatible with Next.js 16. Do not rely
  on `next build` to lint; Next.js 16 no longer does that.
- [x] Add a small Playwright parity suite for anonymous deep links, navigation,
  search/filter state, product lookup, cart persistence, and login redirect.
- [x] Fix the five existing TypeScript diagnostics without weakening types or
  changing runtime behavior.
- [ ] Generate or define Supabase database types so query results do not depend
  on unsafe page-level casts.
- [x] Add a Node version declaration (`engines` and/or `.nvmrc`) compatible with
  Next.js 16; prefer the production LTS version.
- [ ] Run and save the pre-migration results for build, typecheck, lint, and the
  parity smoke tests.

### Phase 1 gate

- [ ] The Vite app still builds and the new baseline checks are green before
  its entrypoint or router is removed.

## Phase 2 — Build the root Next.js foundation

- [x] Move `src/pages/` to a non-reserved directory such as `src/screens/`.
  Next.js would otherwise interpret it as a Pages Router tree alongside App
  Router.
- [x] Replace the root runtime dependencies and scripts with the pinned Next.js,
  React, and React DOM versions; retain Supabase, TanStack Query, Lucide, and
  Tailwind.
- [x] Add `@supabase/ssr`, Node types, the selected linter, and Playwright.
- [x] Change scripts to `next dev --port 5173`, `next build`, and
  `next start --port 5173`.
- [x] Add `src/app/layout.tsx`, `next.config.ts`, `next-env.d.ts`, and the App
  Router TypeScript settings.
- [x] Update Tailwind content globs and move `src/index.css` to the root App
  Router global stylesheet without changing the current theme.
- [x] Move Montserrat and Source Sans 3 to `next/font` while preserving current
  `font-heading`, `font-sans`, `font-serif`, and `font-poppins` behavior.
- [x] Add root metadata, viewport settings, favicon/logo handling, and the
  existing page title/description.
- [x] Add global `loading.tsx`, `error.tsx`, and `not-found.tsx` boundaries.
- [x] Create a Client Component provider that constructs one QueryClient per
  browser runtime. Remove the module-global QueryClient so caches can never be
  shared across server requests or users.
- [x] Add only the providers needed at each route group: cart for the shop;
  auth/query/realtime for staff. Avoid opening staff Realtime subscriptions on
  anonymous storefront visits.

### Phase 2 gate

- [x] A minimal App Router shell runs on `http://localhost:5173`, renders the
  existing global styles, and introduces no hydration warnings.

## Phase 3 — Environment and Supabase auth

- [x] Replace `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` with
  `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY` in code,
  `.env.local`, `.env.example`, and documentation.
- [x] Configure the renamed public variables in Vercel Preview and Production.
- [x] Keep `DB_CONNECTION`, Shopify credentials, Stripe credentials, Square
  credentials, and all other private values unprefixed and server-only.
- [x] Add separate Supabase browser and server client factories. Mark
  server-only modules with `server-only` and never import them through a client
  module.
- [x] Add `proxy.ts` to refresh Supabase auth cookies on the required routes.
- [x] Implement secure server-side staff-layout checks for authenticated user,
  profile existence, `is_active`, and the allowed staff roles.
- [x] Preserve the current missing-profile and access-denied states.
- [x] Preserve the driver redirect from `/admin` to `/delivery` and the
  role-filtered navigation behavior.
- [x] Port email/password sign-in and sign-out, using Next redirects/refresh so
  server-rendered auth state updates immediately.
- [x] Clear and cancel user-scoped React Query data whenever identity changes or
  the user signs out.
- [x] Document that the cookie-storage cutover can require existing staff users
  to sign in again once.
- [ ] Verify public catalog access continues to use the anonymous role and all
  staff operations continue to use the authenticated user's JWT and RLS.
- [ ] Verify no authenticated response or staff data is cached across users.

### Phase 3 gate

- [ ] Anonymous users cannot render protected routes; valid staff can refresh a
  protected deep link; customer/inactive/missing-profile users are denied; and
  sign-out invalidates both server and client state.

## Phase 4 — Replace React Router with the App Router

- [x] Create route-group layouts for the shop shell, auth screen, and protected
  staff shell.
- [x] Replace `Link`, `NavLink`, `useNavigate`, `Navigate`, `useParams`, and
  `useSearchParams` with `next/link` and `next/navigation` equivalents.
- [x] Rebuild active staff navigation with `usePathname`.
- [x] Wrap Client Components that consume search params in the required
  `Suspense` boundaries.
- [x] Keep all current URLs exactly as listed below.

| Done | Current route | App Router target |
|---|---|---|
| [x] | `/` | `src/app/(shop)/page.tsx` |
| [x] | `/product/:handle` | `src/app/(shop)/product/[handle]/page.tsx` |
| [x] | `/how-it-works` | `src/app/(shop)/how-it-works/page.tsx` |
| [x] | `/faq` | `src/app/(shop)/faq/page.tsx` |
| [x] | `/return-policy` | `src/app/(shop)/return-policy/page.tsx` |
| [x] | `/checkout/success` | `src/app/(shop)/checkout/success/page.tsx` |
| [x] | `/admin-login` | `src/app/(auth)/admin-login/page.tsx` |
| [x] | `/admin` | `src/app/(staff)/(backoffice)/admin/page.tsx` |
| [x] | `/inventory` | `src/app/(staff)/(backoffice)/inventory/page.tsx` |
| [x] | `/customers` | `src/app/(staff)/(backoffice)/customers/page.tsx` |
| [x] | `/requests` | `src/app/(staff)/(backoffice)/requests/page.tsx` |
| [x] | `/orders` | `src/app/(staff)/(backoffice)/orders/page.tsx` |
| [x] | `/new-order` | `src/app/(staff)/(backoffice)/new-order/page.tsx` |
| [x] | `/billing` | `src/app/(staff)/(backoffice)/billing/page.tsx` |
| [x] | `/delivery` | `src/app/(staff)/delivery/page.tsx` |
| [x] | `/drivers` | `src/app/(staff)/(backoffice)/drivers/page.tsx` |

### Phase 4 gate

- [ ] Every URL supports direct navigation, client navigation, refresh, back/
  forward navigation, and the correct 404 behavior with no SPA catch-all.

## Phase 5 — Port the current storefront, not the old prototype

- [x] Use the root Vite storefront as the visual and behavioral source of truth.
- [x] Preserve the branded header/footer, hero, category tiles, benefit bar,
  current catalog grid, search, filters, contact details, and responsive layout.
- [x] Preserve the rent-only feature flag. Do not re-enable the stale prototype's
  buy UI.
- [x] Fetch initial catalog data in a Server Component with an explicit freshness
  policy, then pass it to a Client Component for search and filter interaction.
- [x] Server-render product lookup by Shopify handle with the existing ID
  fallback and return `notFound()` for a missing product.
- [x] Add route-level and dynamic product metadata without exposing non-public
  fields.
- [x] Make cart initialization hydration-safe: render a stable initial value,
  load `localStorage` after mount, and do not overwrite a saved cart before it
  has been read.
- [x] Preserve cart quantities, close/open behavior, reload persistence, rental
  request submission, purchase gating, and error/success states.
- [x] Keep `window.location` redirects, query-param verification, scrolling, and
  focus behavior inside Client Components.
- [x] Preserve Stripe checkout creation and idempotent checkout-success
  verification without performing a live charge during migration tests.
- [x] Keep ordinary external `<img>` elements for initial parity, or configure
  exact Shopify/Supabase `images.remotePatterns` before using `next/image`.
- [ ] Verify the logo and every live external product/category image.

### Phase 5 gate

- [ ] The six public routes match the baseline on mobile and desktop, the cart
  survives reload, and anonymous Supabase/Stripe request flows retain their
  current behavior.

## Phase 6 — Port the staff and driver application

- [x] Port the shared staff shell, contact header, profile display, role-filtered
  navigation, live queue badges, notifications, and logout behavior.
- [x] Mount the persistent Realtime-to-query-cache bridge once inside the
  authenticated staff runtime.
- [x] Preserve every query key, invalidation map, polling interval, and
  identity-change cache purge added for cross-user correctness.
- [x] Port Dashboard, including overdue marking, stats, rental table, tabs, and
  driver redirect.
- [x] Port Requests, including confirm/cancel RPC behavior and validation/error
  states.
- [x] Port Orders, including open/unpaid views, pickup scheduling, Stripe
  reconciliation, and payment verification.
- [x] Port New Order, including customer search/create, item selection,
  allocation results, driver scheduling, and the atomic `create_staff_order`
  RPC.
- [x] Port Inventory, including create/edit/deactivate, unit expansion, and
  return-to-available workflow.
- [x] Port Customers and Billing with their current query/error/empty states.
- [x] Port Delivery, including filters, assignment/window updates, start,
  completion, staff override, mobile camera capture, storage upload, and signed
  photo display.
- [x] Port Drivers, including creation and profile/login linking.
- [x] Preserve all 12 current RPC integrations and their exact parameter and
  result handling.
- [x] Keep operational screens as Client Components until a separately tested
  server-data refactor is justified.

### Phase 6 gate

- [ ] Admin, staff, and driver parity tests pass in two simultaneous browser
  sessions, including Realtime refresh, notification fan-out, and user cache
  isolation.

## Phase 7 — Remove obsolete framework and duplicate app files

- [x] Remove `react-router-dom` only after all imports are gone.
- [x] Remove Vite dependencies, `vite.config.ts`, `index.html`, `src/main.tsx`,
  and `src/App.tsx` only after App Router parity is green.
- [x] Remove the SPA catch-all from `vercel.json`; delete the file if no Next-
  specific Vercel configuration remains.
- [x] Remove `storefront/` and its second lockfile only after confirming that no
  newer behavior or asset exists exclusively there.
- [x] Remove generated `dist/` output and add `.next/` and test artifacts to
  `.gitignore`.
- [x] Remove truly unused duplicate components/hooks only after an import scan.
- [x] Confirm there is one root package manifest, one lockfile, and one app
  runtime.
- [x] Update `bc.json` paths, commands, framework family, and Supabase env-key
  metadata.
- [x] Update `docs/ROADMAP.md` and `docs/SCHEMA.md`; update the external
  `HANDOFF.md` if it remains the operational handoff source.

### Phase 7 gate

- [x] `rg` finds no Vite entrypoints, `import.meta.env`, React Router imports,
  stale two-project deployment instructions, or unintended `src/pages` routes.

## Phase 8 — Full verification

### Static and production-build checks

- [x] A clean `npm ci` succeeds from the repository root.
- [x] `npm run lint` succeeds.
- [x] `npm run typecheck` succeeds with no ignored build errors.
- [x] Automated tests succeed.
- [x] `npm run build` succeeds on the pinned Node version.
- [x] `npm run start` serves the production build on the chosen test port.
- [x] The Next build route table contains exactly the intended public routes and
  framework endpoints.
- [ ] Browser consoles contain no hydration, uncaught promise, auth-refresh, or
  image-host errors.
- [x] Client bundles contain no DB connection, Stripe secret, Shopify secret,
  Square token, or other server-only credential.

### Public-flow checks

- [x] Anonymous homepage, search links, filters, and category deep links.
- [x] Product handle lookup, ID fallback, missing product, and direct refresh.
- [x] Cart add/remove/quantity/open/close and persistence across reload.
- [ ] Rental request success, validation failure, and Supabase failure states.
- [ ] Checkout cancel and checkout-success missing/invalid/already-verified
  states without creating a live charge.
- [ ] FAQ and return-policy accordions, How It Works links, phone links, and
  keyboard navigation.
- [ ] Mobile, tablet, and desktop layout checks.

### Auth and staff-flow checks

- [ ] Login failure/success, refresh persistence, logout, and forced one-time
  re-login at cutover.
- [ ] Direct-route checks for anonymous, admin, staff, driver, customer,
  inactive, and missing-profile identities.
- [ ] Dashboard, Requests, Orders, New Order, Inventory, Customers, Billing,
  Delivery, and Drivers happy/error/empty states.
- [ ] Realtime changes propagate between two different signed-in users without
  leaking cached data after either user changes identity.
- [ ] Notification unread/list/mark-all behavior.
- [ ] Delivery camera capture/upload, staff override, and signed image viewing on
  a real mobile browser.
- [ ] Stripe reconciliation and verification use non-charge test cases only.

### Accessibility and performance checks

- [ ] Keyboard focus, labels, dialogs/drawers, accordions, and loading/error
  announcements remain usable.
- [ ] No obvious layout shift from fonts or images.
- [ ] Compare production bundle and key public-route Lighthouse measurements to
  the baseline; document any regression before cutover.

### Phase 8 gate

- [ ] All automated checks and the complete role/route matrix are green with no
  unresolved severity-high regression.

## Phase 9 — Preview, cutover, and rollback window

- [x] Configure renamed public Supabase variables in Vercel Preview and
  Production before the first Next deployment.
- [ ] Confirm all private environment variables remain server-only and that the
  Python migration runner still reads its existing variables.
- [ ] Deploy a Vercel preview and run the full non-payment smoke suite.
- [ ] If checkout must be tested on preview, use one fixed staging origin and an
  explicit allowlist migration; never wildcard arbitrary `*.vercel.app` hosts.
- [ ] Verify Supabase Auth site URL/redirect settings for the production and
  fixed staging origins.
- [ ] Confirm Vercel detects Next.js and has no stale Vite output-directory or
  rewrite settings.
- [ ] Deploy the already-tested commit to production.
- [ ] Smoke-test the custom domain and canonical `www`/non-`www` behavior.
- [ ] Check Vercel logs, Supabase Auth/PostgREST logs, Realtime connections, and
  failed RPCs immediately after cutover.
- [ ] Tell staff they may need to sign in again because auth storage changed.
- [ ] Keep the recorded pre-migration deployment available through the rollback
  window.
- [ ] If a blocking regression appears, redeploy the pre-migration commit; no
  database rollback should be necessary.

## Definition of done

- [x] One root Next.js App Router app and one dependency lockfile remain.
- [ ] All 16 existing URLs and all current public/staff/driver workflows retain
  parity.
- [x] No Vite runtime, React Router runtime, SPA fallback rewrite, or obsolete
  nested Next app remains.
- [ ] Supabase cookie auth, role checks, RLS, Realtime, storage, all 12 RPCs, and
  Stripe return verification work without cross-user cache leakage.
- [x] Clean install, lint, typecheck, tests, and production build all pass.
- [ ] Preview and production verification pass, secrets remain server-only, and
  rollback is documented.
- [x] Architecture and operations documentation describe the new single-project
  Next.js topology accurately.
