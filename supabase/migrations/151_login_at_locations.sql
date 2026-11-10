-- 151: a new staff login can work at several locations from the start.
--
-- Owner, 2026-11-10: with two locations, adding products needed a way to say
-- which location; "make sure this applies to staff too." add_login_at_locations
-- creates the login at the first chosen location (add_branch_login, 087/123)
-- and, when more are chosen, sets them all (set_login_pharmacies) in the same
-- step. If any part is refused, nothing is created. A driver has one home.
--
-- Safe to re-run.

CREATE OR REPLACE FUNCTION public.add_login_at_locations(p_location_ids uuid[], p_role text, p_full_name text, p_phone text, p_username text, p_password text) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'auth', 'extensions' AS $$
DECLARE
  v_ids uuid[] := ARRAY(SELECT DISTINCT x FROM unnest(COALESCE(p_location_ids, '{}'::uuid[])) x WHERE x IS NOT NULL);
  v_created jsonb;
  v_set jsonb;
BEGIN
  IF cardinality(v_ids) = 0 THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_location'); END IF;
  IF p_role = 'driver' AND cardinality(v_ids) > 1 THEN RETURN jsonb_build_object('ok', false, 'reason', 'driver_one_home'); END IF;
  BEGIN
    v_created := public.add_branch_login(v_ids[1], p_role, p_full_name, p_phone, p_username, p_password);
    IF NOT COALESCE((v_created->>'ok')::boolean, false) THEN RETURN v_created; END IF;
    IF cardinality(v_ids) > 1 THEN
      v_set := public.set_login_pharmacies((v_created->>'profile_id')::uuid, v_ids);
      IF NOT COALESCE((v_set->>'ok')::boolean, false) THEN
        RAISE EXCEPTION 'locations refused: %', v_set->>'reason' USING ERRCODE = 'P0001', HINT = v_set->>'reason';
      END IF;
    END IF;
  EXCEPTION WHEN raise_exception THEN
    -- The login created above is undone with this block.
    RETURN jsonb_build_object('ok', false, 'reason', regexp_replace(SQLERRM, '^locations refused: ', ''));
  END;
  RETURN v_created || jsonb_build_object('location_ids', to_jsonb(v_ids));
END $$;
REVOKE ALL ON FUNCTION public.add_login_at_locations(uuid[], text, text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_login_at_locations(uuid[], text, text, text, text, text) TO authenticated;
