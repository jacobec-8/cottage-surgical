/** Return `href` with the `key` search param set to `id`, or removed when `id` is null. */
export function withSelectedParam(href: string, key: string, id: string | null): string {
  const url = new URL(href)
  if (id) url.searchParams.set(key, id)
  else url.searchParams.delete(key)
  return url.toString()
}
