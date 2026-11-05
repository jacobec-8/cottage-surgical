-- Stand-ins for what Supabase provides and a plain PostgreSQL does not.
-- Loaded before 000_baseline.sql in the disposable test clusters. No network,
-- no secrets: the http() stand-in refuses to run, and tests replace the
-- functions that would call it.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN CREATE ROLE anon; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN CREATE ROLE service_role BYPASSRLS; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'postgres') THEN CREATE ROLE postgres; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_admin') THEN CREATE ROLE supabase_admin; END IF;
END $$;
CREATE SCHEMA auth;
-- Supabase keeps pgcrypto in `extensions`; login creation hashes passwords with it.
CREATE SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE SCHEMA vault;
CREATE TABLE auth.users (
  instance_id uuid, id uuid PRIMARY KEY, aud text, role text, email text UNIQUE,
  encrypted_password text, email_confirmed_at timestamptz, raw_app_meta_data jsonb,
  raw_user_meta_data jsonb DEFAULT '{}', created_at timestamptz DEFAULT now(), updated_at timestamptz,
  confirmation_token text, recovery_token text, email_change_token_new text, email_change text,
  last_sign_in_at timestamptz
);
CREATE TABLE auth.identities (
  id uuid PRIMARY KEY, user_id uuid REFERENCES auth.users, identity_data jsonb, provider text,
  provider_id text, last_sign_in_at timestamptz, created_at timestamptz, updated_at timestamptz
);
CREATE TABLE auth.sessions (id uuid PRIMARY KEY, user_id uuid REFERENCES auth.users, created_at timestamptz DEFAULT now());
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;
CREATE TABLE vault.decrypted_secrets (name text PRIMARY KEY, decrypted_secret text);
-- pgsql-http shapes, so functions that declare these types load.
CREATE TYPE public.http_header AS (field text, value text);
CREATE TYPE public.http_request AS (method text, uri text, headers public.http_header[], content_type text, content text);
CREATE TYPE public.http_response AS (status integer, content_type text, headers public.http_header[], content text);
CREATE FUNCTION public.http(public.http_request) RETURNS public.http_response LANGUAGE plpgsql AS $$
  BEGIN RAISE EXCEPTION 'http() is not available in tests'; END $$;
GRANT USAGE ON SCHEMA public, auth TO anon, authenticated, service_role;
