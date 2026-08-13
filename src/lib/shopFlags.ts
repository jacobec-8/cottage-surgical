/**
 * Storefront feature flags for the pharmacy rental launch.
 * Purchase/buy paths stay in the codebase (cart mode, Stripe RPCs, staff UI)
 * but are hidden from customers until sales go live.
 */
export const SHOP_PURCHASES_ENABLED = false
