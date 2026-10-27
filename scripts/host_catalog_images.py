#!/usr/bin/env python3
"""Copy externally hosted catalog images into our equipment-images bucket.

    DB_CONNECTION=... NEXT_PUBLIC_SUPABASE_URL=... NEXT_PUBLIC_SUPABASE_ANON_KEY=... \
    STAFF_USER=... STAFF_PASSWORD_FILE=... python3 scripts/host_catalog_images.py [--apply]

The retail catalog (091) linked product photos on other companies' sites, and
some of them refuse to be shown elsewhere ("this image was hotlinked"). Each
external image is downloaded once, checked to be a real image, uploaded as
catalog/<handle>.<ext> by a signed-in admin (the same path the app uses), and
the product is pointed at our copy. Images that no longer exist (404/403/410) are cleared so the
placeholder shows; other failures keep the old URL. All are listed.
"""
import concurrent.futures
import json
import os
import sys
import urllib.request

import psycopg2

URL = os.environ["NEXT_PUBLIC_SUPABASE_URL"].rstrip("/")
ANON = os.environ["NEXT_PUBLIC_SUPABASE_ANON_KEY"]
APPLY = "--apply" in sys.argv[1:]
TYPES = {"image/jpeg": "jpg", "image/pjpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/gif": "gif"}
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130 Safari/537.36"


def token() -> str:
    body = json.dumps({
        "email": f"{os.environ['STAFF_USER']}@staff-login.cottagesurgical.invalid",
        "password": open(os.environ["STAFF_PASSWORD_FILE"]).read(),
    }).encode()
    req = urllib.request.Request(f"{URL}/auth/v1/token?grant_type=password", data=body,
                                 headers={"apikey": ANON, "Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req))["access_token"]


def copy(item: tuple, jwt: str) -> tuple:
    item_id, handle, src = item
    try:
        resp = urllib.request.urlopen(urllib.request.Request(src, headers={"User-Agent": UA}), timeout=20)
        kind = resp.headers.get_content_type()
        data = resp.read()
        if kind not in TYPES or len(data) < 2000:
            return item_id, None, f"not an image ({kind}, {len(data)} bytes)"
        path = f"catalog/{handle}.{TYPES[kind]}"
        if APPLY:
            up = urllib.request.Request(f"{URL}/storage/v1/object/equipment-images/{path}", data=data, method="POST",
                                        headers={"apikey": ANON, "Authorization": f"Bearer {jwt}", "Content-Type": "image/jpeg" if kind == "image/pjpeg" else kind})
            urllib.request.urlopen(up, timeout=30).read()
        return item_id, f"{URL}/storage/v1/object/public/equipment-images/{path}", None
    except Exception as e:  # noqa: BLE001 - report every failure, keep going
        return item_id, None, str(e)[:120]


conn = psycopg2.connect(os.environ["DB_CONNECTION"])
cur = conn.cursor()
cur.execute("""SELECT id::text, shopify_handle, image_url FROM equipment_items
               WHERE shopify_handle IS NOT NULL AND image_url LIKE 'http%%' AND image_url NOT LIKE %s""", (f"{URL}%",))
items = cur.fetchall()
jwt = token()
done, failed = 0, []
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    for item_id, new_url, problem in pool.map(lambda it: copy(it, jwt), items):
        if new_url:
            cur.execute("UPDATE equipment_items SET image_url = %s WHERE id = %s", (new_url, item_id))
            done += 1
        else:
            failed.append((item_id, problem))
            if "404" in problem or "403" in problem or "410" in problem:
                # The source image is gone: show the plain placeholder, not a broken image.
                cur.execute("UPDATE equipment_items SET image_url = NULL WHERE id = %s", (item_id,))
print(f"{len(items)} external images: {done} copied, {len(failed)} kept as-is")
for item_id, problem in failed:
    print("  kept", item_id, problem)
if APPLY:
    conn.commit()
else:
    conn.rollback()
    print("dry run: nothing uploaded or changed (pass --apply)")
