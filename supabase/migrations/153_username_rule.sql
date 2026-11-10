-- 153: usernames may use dots and underscores.
--
-- Owner, 2026-11-10: "clt_staff" was refused with "Usernames use 3–63
-- lowercase letters, numbers or dashes" — "im not sure this is a legitimate
-- constraint." A username signs in as name@staff-login.cottagesurgical.invalid,
-- so it must be a valid email name, and dots and underscores are. Usernames
-- now take 3–63 letters, numbers, dots, dashes and underscores, starting with
-- a letter or number, with no two dots in a row and no dot at the end.
-- (Spaces and @ still can't be part of an email name.)
--
-- Each function holding the old rule or its message is re-created from its
-- own definition with only that text swapped. Rx Companion is never touched.
--
-- Safe to re-run.

DO $$
DECLARE
  r RECORD;
  v_def TEXT;
  v_new TEXT;
  v_pair TEXT[];
  v_pairs TEXT[][] := ARRAY[
    ARRAY['^[a-z0-9][a-z0-9-]{2,62}$', '^(?!.*\.\.)(?!.*\.$)[a-z0-9][a-z0-9._-]{2,62}$'],
    ARRAY['use 3–63 letters, numbers, or hyphens for the username; start with a letter or number.', 'use 3–63 letters, numbers, dots, dashes or underscores for the username, starting with a letter or number.'],
    ARRAY['use 3–63 letters, numbers, or hyphens for the username.', 'use 3–63 letters, numbers, dots, dashes or underscores for the username, starting with a letter or number.'],
    ARRAY['use 3–63 letters, numbers, or hyphens; start with a letter or number.', 'use 3–63 letters, numbers, dots, dashes or underscores, starting with a letter or number.']
  ];
BEGIN
  FOR r IN
    SELECT p.oid FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f' AND p.proname NOT LIKE 'rx\_%'
       AND (p.prosrc LIKE '%[a-z0-9][a-z0-9-]{2,62}%' OR p.prosrc LIKE '%or hyphens%')
  LOOP
    v_def := pg_get_functiondef(r.oid);
    v_new := v_def;
    FOREACH v_pair SLICE 1 IN ARRAY v_pairs LOOP
      v_new := replace(v_new, v_pair[1], v_pair[2]);
    END LOOP;
    IF v_new <> v_def THEN EXECUTE v_new; END IF;
  END LOOP;
END $$;
