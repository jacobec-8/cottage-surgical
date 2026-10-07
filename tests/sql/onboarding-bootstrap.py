"""Emit an isolated schema from real migration fragments, never a live DB.

Supabase auth tables are minimal stand-ins; public tables, stock triggers,
profile guards and account RPCs are sourced from the actual migrations.
"""
from pathlib import Path
root = Path(__file__).resolve().parents[2] / 'supabase/migrations'
def read(name): return (root / name).read_text()
def section(name, start, end): return read(name).split(start, 1)[1].split(end, 1)[0]
print('''
CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role;
CREATE SCHEMA auth; CREATE SCHEMA extensions;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
 SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;
GRANT USAGE ON SCHEMA public, auth TO anon, authenticated, service_role;
CREATE TABLE auth.users (
 instance_id uuid, id uuid PRIMARY KEY, aud text, role text, email text UNIQUE,
 encrypted_password text, email_confirmed_at timestamptz, raw_app_meta_data jsonb,
 raw_user_meta_data jsonb, created_at timestamptz, updated_at timestamptz,
 confirmation_token text, recovery_token text, email_change_token_new text, email_change text
);
CREATE TABLE auth.identities (id uuid PRIMARY KEY, user_id uuid REFERENCES auth.users,
 identity_data jsonb, provider text, provider_id text, last_sign_in_at timestamptz,
 created_at timestamptz, updated_at timestamptz);
''')
for name in ['001_extensions_and_helpers.sql', '002_profiles.sql', '005_equipment.sql', '006_drivers.sql']:
    print(read(name))
print(read('015_storefront.sql').split('-- ── Customers:', 1)[0])
print('CREATE TABLE IF NOT EXISTS public.pickup_locations (' + section('053_storefront_fulfillment.sql', 'CREATE TABLE IF NOT EXISTS public.pickup_locations (', 'CREATE TABLE IF NOT EXISTS public.equipment_item_pickup_locations'))
print(read('054_multi_location_tenancy.sql').split('INSERT INTO public.businesses', 1)[0])
print('ALTER TABLE public.pickup_locations' + section('054_multi_location_tenancy.sql', 'ALTER TABLE public.pickup_locations', 'UPDATE public.pickup_locations\nSET business_id'))
print(section('054_multi_location_tenancy.sql', 'WHERE business_id IS NULL;', '-- Existing non-admin operational accounts'))
print('ALTER TABLE public.equipment_items ADD COLUMN pickup_enabled boolean NOT NULL DEFAULT true, ADD COLUMN delivery_enabled boolean NOT NULL DEFAULT true, ADD COLUMN pickup_rental_price numeric(10,2), ADD COLUMN delivery_rental_price numeric(10,2);')
print('CREATE TABLE IF NOT EXISTS public.equipment_location_inventory (' + section('054_multi_location_tenancy.sql', 'CREATE TABLE IF NOT EXISTS public.equipment_location_inventory (', 'INSERT INTO public.equipment_location_inventory ('))
print('ALTER TABLE public.equipment_units ADD COLUMN location_id uuid REFERENCES public.pickup_locations; ALTER TABLE public.drivers ADD COLUMN location_id uuid REFERENCES public.pickup_locations;')
print('CREATE OR REPLACE FUNCTION public.refresh_location_quantity_on_hand()' + section('054_multi_location_tenancy.sql', 'CREATE OR REPLACE FUNCTION public.refresh_location_quantity_on_hand()', '-- Align the initial per-location counts'))
print('CREATE TABLE public.equipment_item_pickup_locations(equipment_item_id uuid REFERENCES public.equipment_items, pickup_location_id uuid REFERENCES public.pickup_locations, PRIMARY KEY(equipment_item_id,pickup_location_id));')
# Include the current stock/pickup synchronization triggers, not old defaults.
print(read('061_pickup_requires_stock.sql').split('-- Seed every', 1)[0])
print('''CREATE TRIGGER sync_storefront_pickup_location AFTER INSERT OR UPDATE OR DELETE ON public.equipment_location_inventory FOR EACH ROW EXECUTE FUNCTION public.sync_storefront_pickup_location();
CREATE TRIGGER sync_storefront_pickup_locations_for_location AFTER UPDATE OF is_active ON public.pickup_locations FOR EACH ROW EXECUTE FUNCTION public.sync_storefront_pickup_locations_for_location();''')
print(read('059_location_user_accounts.sql'))
print('GRANT SELECT ON public.profiles TO authenticated;')
print(read('062_guided_location_onboarding.sql'))
# Verify replay safety, matching the repository's migration runner.
print(read('062_guided_location_onboarding.sql'))
