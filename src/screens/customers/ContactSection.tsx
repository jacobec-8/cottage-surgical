'use client'

import { businessToday } from '../delivery/stopStatus'
import { Section } from '../orders/DetailSections'
import {
  addressChange, addressLabel, birthDateChange, COVERAGE_OPTIONS, coverageChange, coverageLabel,
  emailChange, nameChange, phoneChange, textChange,
} from './contactRules'
import { AddressEditor, EditableRow, SelectEditor, TextEditor } from './EditableRow'
import type { CustomerRecord } from './useCustomerDetail'
import { useSaveCustomer } from './useSaveCustomer'

const LONG_DATE: Intl.DateTimeFormatOptions = { month: 'short', day: 'numeric', year: 'numeric' }

// A date-only value is read at noon so no time zone moves it to another day.
function birthDate(dob: string | null): string | null {
  return dob ? new Date(`${dob}T12:00:00`).toLocaleDateString('en-US', LONG_DATE) : null
}

/** Contact, coverage and notes; every field edits in place for the store's staff. */
export default function ContactSection({ c }: { c: CustomerRecord }) {
  const save = useSaveCustomer(c.id)
  return (
    <Section title="Contact & coverage">
      <dl className="grid gap-x-6 gap-y-4 rounded-lg border border-slate-200 bg-white p-4 sm:grid-cols-2">
        <EditableRow label="Name" value={c.full_name}
          editor={(done) => <TextEditor label="Name" initial={c.full_name} check={nameChange} save={save} done={done} />} />
        <EditableRow label="Phone" value={c.phone} empty="Not set"
          editor={(done) => <TextEditor label="Phone" type="tel" initial={c.phone ?? ''} check={phoneChange} save={save} done={done} />} />
        <EditableRow label="Email" value={c.email} empty="Not set"
          editor={(done) => <TextEditor label="Email" type="email" initial={c.email ?? ''} check={emailChange} save={save} done={done} />} />
        <EditableRow label="Date of birth" value={birthDate(c.date_of_birth)} empty="Not set"
          editor={(done) => <TextEditor label="Date of birth" type="date" initial={c.date_of_birth ?? ''} check={(v) => birthDateChange(v, businessToday())} save={save} done={done} />} />
        <div className="sm:col-span-2">
          <EditableRow label="Address" value={addressLabel(c)} empty="No address on file"
            editor={(done) => <AddressEditor initial={{ line1: c.address_line1 ?? '', city: c.address_city ?? '', state: c.address_line1 ? c.address_state ?? '' : '', zip: c.address_zip ?? '' }}
              check={addressChange} save={save} done={done} />} />
        </div>
        <EditableRow label="Coverage" value={coverageLabel(c.coverage_type)} empty="Not set"
          editor={(done) => <SelectEditor label="Coverage" initial={c.coverage_type ?? ''} options={COVERAGE_OPTIONS} check={coverageChange} save={save} done={done} />} />
        <EditableRow label="Insurance notes" value={c.insurance_notes} empty="None"
          editor={(done) => <TextEditor label="Insurance notes" multiline initial={c.insurance_notes ?? ''} check={(v) => textChange('insurance_notes', v)} save={save} done={done} />} />
        <div className="sm:col-span-2">
          <EditableRow label="Notes" value={c.notes} empty="None"
            editor={(done) => <TextEditor label="Notes" multiline initial={c.notes ?? ''} check={(v) => textChange('notes', v)} save={save} done={done} />} />
        </div>
        <EditableRow label="Customer since" value={new Date(c.created_at).toLocaleDateString('en-US', LONG_DATE)} />
      </dl>
    </Section>
  )
}
