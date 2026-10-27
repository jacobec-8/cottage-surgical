/** Website price: "$75" for whole dollars, otherwise exact cents ("$19.99"); never rounded. */
export function shopPrice(amount: number): string {
  const cents = Math.round(amount * 100)
  const whole = cents % 100 === 0
  return `$${(cents / 100).toLocaleString('en-US', { minimumFractionDigits: whole ? 0 : 2, maximumFractionDigits: whole ? 0 : 2 })}`
}
