"""Emit an isolated email-test schema using real migration tables/functions.

Auth and the HTTP sender are local stand-ins. There are no provider secrets,
cron jobs, network calls or connections to a live database in this bootstrap.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2] / 'supabase/migrations'

def read(name):
    return (ROOT / name).read_text()

def function(name, file):
    sql = read(file)
    match = re.search(r'CREATE OR REPLACE FUNCTION public\.' + name + r'\s*\([\s\S]*?\n\$(\w*)\$;', sql)
    if not match:
        raise RuntimeError('Missing migration function ' + name)
    return match.group()

print('''
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role BYPASSRLS; END IF;
END $$;
CREATE SCHEMA auth;
CREATE TABLE auth.users(id uuid PRIMARY KEY, email text, raw_user_meta_data jsonb DEFAULT '{}');
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
 SELECT NULLIF(current_setting('request.jwt.claim.sub',true),'')::uuid;
$$;
GRANT USAGE ON SCHEMA public,auth TO anon,authenticated,service_role;
''')
for name in ['001_extensions_and_helpers.sql', '002_profiles.sql', '004_customers.sql',
             '005_equipment.sql', '006_drivers.sql', '007_rental_orders.sql',
             '008_deliveries.sql', '010_billing.sql']:
    print(read(name))
print(function('app_role', '018_review_fixes_2.sql'))
# Relevant additive schema from the storefront/tenancy/payment migrations.
print('''
CREATE TABLE public.pickup_locations(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 name text NOT NULL, address_line1 text,address_line2 text,address_city text,
 address_state text,address_zip text,is_active boolean DEFAULT true);
ALTER TABLE public.profiles ADD COLUMN location_id uuid REFERENCES pickup_locations;
ALTER TABLE public.customers ADD COLUMN location_id uuid REFERENCES pickup_locations;
ALTER TABLE public.rental_orders ADD COLUMN location_id uuid REFERENCES pickup_locations,
 ADD COLUMN source text DEFAULT 'storefront',ADD COLUMN fulfillment_method text DEFAULT 'delivery',
 ADD COLUMN pickup_location_id uuid REFERENCES pickup_locations,
 ADD COLUMN payment_status text DEFAULT 'unpaid',ADD COLUMN payment_preference text DEFAULT 'on_delivery';
ALTER TABLE public.rental_orders DROP CONSTRAINT rental_orders_status_check;
ALTER TABLE public.rental_orders ADD CHECK(status IN ('pending_payment','requested','open',
 'pending','scheduled','delivered','active','overdue','pickup_scheduled','closed','cancelled'));
ALTER TABLE public.rental_line_items ADD COLUMN bulk_stock text;
ALTER TABLE public.deliveries ADD COLUMN requires_driver boolean DEFAULT true,
 ADD COLUMN location_id uuid REFERENCES pickup_locations;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO authenticated;
''')
print(function('current_location_id', '054_multi_location_tenancy.sql'))
print(function('can_access_location', '054_multi_location_tenancy.sql'))
# The response type allows loading the original sender; it is replaced with
# the inert sender below before any fixture operation can dispatch mail.
print('CREATE TYPE public.http_response AS (status integer, content_type text, headers jsonb, content text);')
# The production outbox/schema/content/triggers, with an inert sender at runtime.
print(read('045_customer_status_emails.sql'))
print(read('050_customer_email_content.sql'))
print('''CREATE TRIGGER trg_refresh_request_details_email AFTER INSERT OR DELETE OR UPDATE OF
 equipment_item_id,quantity,monthly_rate,sale_price ON public.rental_line_items
 FOR EACH ROW EXECUTE FUNCTION public.refresh_request_details_email();''')
print('''
CREATE TRIGGER trg_queue_delivery_schedule_email AFTER INSERT OR UPDATE OF
 scheduled_date,window_start,window_end,window_label,status ON public.deliveries
 FOR EACH ROW EXECUTE FUNCTION public.queue_delivery_schedule_email();
CREATE FUNCTION public.order_unallocated_count(p_order_id uuid) RETURNS integer
 LANGUAGE sql STABLE AS $$ SELECT count(*)::int FROM public.rental_line_items li
 JOIN public.equipment_items ei ON ei.id=li.equipment_item_id
 WHERE li.order_id=p_order_id AND li.equipment_unit_id IS NULL AND ei.is_serialized $$;
CREATE TABLE public.test_email_sends(email_id uuid);
CREATE OR REPLACE FUNCTION public.send_customer_status_email(p_email_id uuid) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
 BEGIN INSERT INTO test_email_sends VALUES(p_email_id);
 UPDATE customer_email_outbox SET status='sent',sent_at=now() WHERE id=p_email_id;
 RETURN jsonb_build_object('ok',true); END $$;
REVOKE ALL ON FUNCTION public.send_customer_status_email(uuid) FROM PUBLIC,anon,authenticated;
''')
for name in ['070_customer_email_store_isolation.sql', '071_customer_email_lifecycle.sql',
             '072_customer_billing_reminders.sql']:
    if (ROOT / name).exists():
        print(read(name))
