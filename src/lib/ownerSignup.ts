// A business owner signs themselves up; an admin approves before the login
// works (owner, 2026-11-10; migration 143). The form's own checks match what
// submit_owner_signup refuses, so a mistake is caught on the field first.
import { problems, rules, type FieldProblem } from './fieldRules.ts'
import { MIN_PASSWORD_LENGTH, validUsername } from './storeLogins.ts'
import { isLoginEmail } from './staffLogin.ts'

export type OwnerSignupDraft = {
  businessName: string
  fullName: string
  phone: string
  email: string
  username: string
  password: string
}

export const emptySignup: OwnerSignupDraft = { businessName: '', fullName: '', phone: '', email: '', username: '', password: '' }

const MAX_PASSWORD_BYTES = 72

const REASONS: Record<string, string> = {
  invalid_business: 'Enter your business name.',
  invalid_name: 'Enter your name.',
  invalid_phone: 'Enter a phone number with at least 10 digits.',
  invalid_email: 'Enter an email like name@example.com.',
  invalid_username: 'Use your email, or a username of 3–63 lowercase letters, numbers or hyphens.',
  username_taken: 'That login is already in use. Choose another.',
  weak_password: `Use a password of at least ${MIN_PASSWORD_LENGTH} characters.`,
  already_waiting: 'A sign-up with this email is already waiting for approval.',
  busy: 'We can’t take new sign-ups right now. Please try again later or call us.',
}

/** Owner-readable text for a refusal from submit_owner_signup. */
export function signupMessage(reason: string | undefined): string {
  return (reason && REASONS[reason]) || 'Couldn’t send your sign-up. Please try again.'
}

export function signupProblems(d: OwnerSignupDraft): FieldProblem[] {
  const bytes = new TextEncoder().encode(d.password).length
  return problems(
    d.businessName.trim().length < 2 && { field: 'businessName', message: REASONS.invalid_business },
    rules.required(d.fullName, 'fullName', REASONS.invalid_name),
    rules.phone(d.phone, 'phone', REASONS.invalid_phone),
    rules.email(d.email, 'email', 'Enter your email.'),
    !validUsername(d.username) && !isLoginEmail(d.username) && { field: 'username', message: REASONS.invalid_username },
    d.password.length < MIN_PASSWORD_LENGTH && { field: 'password', message: REASONS.weak_password },
    bytes > MAX_PASSWORD_BYTES && { field: 'password', message: 'That password is too long. Use a shorter one.' },
  )
}

/** What submit_owner_signup takes. */
export function signupPayload(d: OwnerSignupDraft) {
  return {
    business_name: d.businessName.trim(),
    full_name: d.fullName.trim(),
    phone: d.phone.trim(),
    email: d.email.trim().toLowerCase(),
    username: d.username.trim().toLowerCase(),
    password: d.password,
  }
}

/** What the sign-in page says when a sign-in fails for a username with a request. */
export function signupStatusMessage(status: string | null): string | null {
  if (status === 'pending') return 'Your sign-up is waiting for approval. You can sign in once an admin approves it.'
  if (status === 'declined') return 'Your sign-up was not approved. Please contact us if you think this is a mistake.'
  return null
}
