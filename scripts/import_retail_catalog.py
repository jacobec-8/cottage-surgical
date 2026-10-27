#!/usr/bin/env python3
"""Load the Cottage Pharmacy retail list into the shared catalog (091).

    DB_CONNECTION=... python3 scripts/import_retail_catalog.py path/to/shopify_import.csv [--apply]

Each product becomes a bulk, for-sale item at $0 ("call for pricing") that the
website does not list until a store stocks it and staff set a price
(storefront_listed). Products already loaded (same Shopify handle) are skipped,
so the script can be re-run. Without --apply it reports and rolls back.
"""
import csv
import html
import os
import re
import sys

import psycopg2

if len(sys.argv) < 2 or not os.path.exists(sys.argv[1]):
    sys.exit(__doc__)
path, apply = sys.argv[1], "--apply" in sys.argv[2:]


def plain_text(body: str) -> str:
    """Shopify body HTML → one paragraph of plain text."""
    text = re.sub(r"<li>", " • ", body or "")
    text = re.sub(r"<[^>]+>", " ", text)
    return re.sub(r"\s+", " ", html.unescape(text)).strip()


rows = [r for r in csv.DictReader(open(path, newline="", encoding="utf-8")) if r.get("Title")]
conn = psycopg2.connect(os.environ["DB_CONNECTION"])
cur = conn.cursor()
added = skipped = 0
for r in rows:
    cur.execute("SELECT 1 FROM equipment_items WHERE shopify_handle = %s", (r["Handle"],))
    if cur.fetchone():
        skipped += 1
        continue
    cur.execute(
        """INSERT INTO equipment_items (name, description, category, vendor, image_url, shopify_handle,
             is_serialized, is_rentable, is_purchasable, sale_price, pickup_enabled, delivery_enabled,
             is_active, list_when_out_of_stock)
           VALUES (%s, %s, %s, %s, %s, %s, false, false, true, 0, true, true, true, false)""",
        (r["Title"].strip(), plain_text(r["Body (HTML)"]), r["Type"].strip().lower(),
         r["Vendor"].strip() or None, r["Image Src"].strip() or None, r["Handle"]),
    )
    added += 1

cur.execute("SELECT count(*) FROM equipment_items i WHERE shopify_handle IS NOT NULL AND public.storefront_listed(i) AND NOT i.is_rentable")
listed = cur.fetchone()[0]
print(f"{added} added, {skipped} already loaded; retail items listed on the website now: {listed}")
if apply:
    conn.commit()
    print("committed")
else:
    conn.rollback()
    print("dry run: rolled back (pass --apply to load)")
