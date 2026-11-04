"""Emit the email-test schema: Supabase stand-ins, the real schema from
000_baseline.sql, then an inert mail sender so no message can leave the box.

There are no provider secrets, cron jobs, network calls or connections to a
live database in this bootstrap.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read(path: str) -> str:
    return (ROOT / path).read_text()


print(read("tests/sql/standins.sql"))
print(read("supabase/migrations/000_baseline.sql"))
print(
    """
CREATE TABLE public.test_email_sends (email_id uuid);
-- Keep the real sender under another name; customer-email-provider.sql restores it.
ALTER FUNCTION public.send_customer_status_email(uuid) RENAME TO send_customer_status_email_real;
CREATE FUNCTION public.send_customer_status_email(p_email_id uuid) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
 BEGIN
   INSERT INTO test_email_sends VALUES (p_email_id);
   UPDATE customer_email_outbox SET status = 'sent', sent_at = now() WHERE id = p_email_id;
   RETURN jsonb_build_object('ok', true);
 END $$;
REVOKE ALL ON FUNCTION public.send_customer_status_email(uuid) FROM PUBLIC, anon, authenticated;
"""
)
