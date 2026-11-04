import { test } from 'node:test'
import assert from 'node:assert/strict'
import { FIELD_MESSAGES as M, problems, rules } from '../../src/lib/fieldRules.ts'

// One shared set of field rules (enterprise hardening, code-level checks).
// Each rule names the field it is about, so the form can mark that field.

test('required names its field and passes a filled value', () => {
  assert.deepEqual(rules.required('  ', 'name', 'Enter a name.'), { field: 'name', message: 'Enter a name.' })
  assert.equal(rules.required('Pat', 'name', 'Enter a name.'), null)
})

test('price accepts dollars and cents, refuses negatives, letters and extra decimals', () => {
  for (const ok of ['0', '45', '45.5', '45.50']) assert.equal(rules.price(ok, 'sale'), null)
  for (const bad of ['-5', '$450', '1,200', '45.505', 'abc', '4 5']) {
    assert.deepEqual(rules.price(bad, 'sale'), { field: 'sale', message: M.price })
  }
  assert.equal(rules.price('', 'sale'), null)
  assert.deepEqual(rules.price('', 'sale', 'Enter the sale price.'), { field: 'sale', message: 'Enter the sale price.' })
})

test('whole number refuses negatives, decimals and very large values', () => {
  for (const ok of ['0', '12']) assert.equal(rules.wholeNumber(ok, 'qty'), null)
  for (const bad of ['-1', '1.5', 'ten', '100001']) assert.deepEqual(rules.wholeNumber(bad, 'qty'), { field: 'qty', message: M.wholeNumber })
  assert.equal(rules.wholeNumber('', 'qty'), null)
  assert.deepEqual(rules.wholeNumber('', 'qty', 'Enter the quantity.'), { field: 'qty', message: 'Enter the quantity.' })
})

test('email, phone, ZIP and state use the same words everywhere', () => {
  assert.equal(rules.email('pat@example.com', 'email'), null)
  assert.deepEqual(rules.email('pat@', 'email'), { field: 'email', message: M.email })
  assert.equal(rules.email('', 'email'), null)
  assert.deepEqual(rules.email('', 'email', 'Enter an email.'), { field: 'email', message: 'Enter an email.' })

  assert.equal(rules.phone('(516) 555-0100', 'phone'), null)
  assert.deepEqual(rules.phone('555-0100', 'phone'), { field: 'phone', message: M.phone })
  assert.equal(rules.phone('', 'phone'), null)

  for (const ok of ['11968', '11968-1234']) assert.equal(rules.zip(ok, 'zip'), null)
  assert.deepEqual(rules.zip('1196', 'zip'), { field: 'zip', message: M.zip })

  assert.equal(rules.state('ny', 'state'), null)
  assert.deepEqual(rules.state('New York', 'state'), { field: 'state', message: M.state })
})

test('problems keeps every problem in field order and drops the passes', () => {
  const found = problems(
    rules.required('', 'name', 'Enter a name.'),
    rules.email('ok@example.com', 'email'),
    rules.price('-1', 'sale'),
    false,
    null,
  )
  assert.deepEqual(found.map((p) => p.field), ['name', 'sale'])
})

test('a problem about the whole form has no field', () => {
  assert.deepEqual(rules.form('Choose a store in the header first.'), { field: null, message: 'Choose a store in the header first.' })
})
