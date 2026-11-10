-- 148: customer emails and staff messages stop saying "pharmacy".
--
-- Owner, 2026-11-10: "get rid of pharmacy wording, and just keep it abstract
-- to business, i think we could actually onboard non-pharmacies." The app's
-- screens now say location and business. This does the same for the text
-- the database writes: customer emails speak as "we" and "us", and the
-- messages staff see say location. Table and function names stay.
--
-- Each function whose text holds one of these phrases is re-created from its
-- own definition with the phrase swapped, so nothing else in it changes.
-- Rx Companion's functions are never touched.
--
-- Safe to re-run.

DO $$
DECLARE
  r RECORD;
  v_def TEXT;
  v_new TEXT;
  v_pair TEXT[];
  v_pairs TEXT[][] := ARRAY[
    ARRAY['Offline payment recorded by the pharmacy', 'Offline payment recorded in store'],
    ARRAY['Offline payment recorded by pharmacy', 'Offline payment recorded in store'],
    ARRAY['This receipt confirms the pharmacy recorded your payment', 'This receipt confirms we recorded your payment'],
    ARRAY['Please contact the pharmacy', 'Please contact us'],
    ARRAY['Reply to it to reach the pharmacy', 'Reply to it to reach us'],
    ARRAY['Paid to the pharmacy', 'Paid in store'],
    ARRAY['The pharmacy will call you', 'We will call you'],
    ARRAY['a call from the pharmacy', 'a call from us'],
    ARRAY['Your equipment is reserved at the pharmacy.', 'Your equipment is reserved for you.'],
    ARRAY['Deposit kept by the pharmacy', 'Deposit kept'],
    ARRAY['is turned off for staff at this pharmacy', 'is turned off for staff at this location'],
    ARRAY['the owner of a pharmacy are set by an admin', 'the owner of a location are set by an admin'],
    ARRAY['role and pharmacies are set through memberships', 'role and locations are set through memberships'],
    ARRAY['own owner''''s pharmacies', 'own owner''''s locations'],
    ARRAY['Only the owner chooses which pharmacies are on the website', 'Only the owner chooses which locations are on the website'],
    ARRAY['''Pharmacy not found''', '''Location not found''']
  ];
BEGIN
  FOR r IN
    SELECT p.oid FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'
       AND p.proname NOT LIKE 'rx\_%' AND p.prosrc ~* 'pharmac'
  LOOP
    v_def := pg_get_functiondef(r.oid);
    v_new := v_def;
    FOREACH v_pair SLICE 1 IN ARRAY v_pairs LOOP
      v_new := replace(v_new, v_pair[1], v_pair[2]);
    END LOOP;
    IF v_new <> v_def THEN EXECUTE v_new; END IF;
  END LOOP;
END $$;
