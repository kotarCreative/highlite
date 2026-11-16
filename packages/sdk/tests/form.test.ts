import { describe, expect, it } from 'vitest';
import {
  MAX_FIELD_VALUE_LENGTH,
  TextEditCoalescer,
  boundedFieldValue,
  changePayload,
  classifyField,
  isSubmitControlDescriptor,
  submitPayload,
  textEditPayload,
  type FieldDescriptor,
  type FieldPolicy,
} from '../src/form';

const textField: FieldDescriptor = {
  tagName: 'input',
  type: 'text',
  name: 'query',
  id: 'query',
  label: 'Search',
};

function policy(captureValues: boolean): FieldPolicy {
  return { captureValues };
}

describe('form field classification', () => {
  it('does not capture values by default', () => {
    const classification = classifyField(textField, policy(false));

    expect(classification.kind).toBe('text');
    expect(classification.captureValue).toBe(false);
    expect(textEditPayload(classification, 'retention')).toEqual({
      fieldKind: 'text',
      fieldType: 'text',
      filled: true,
      valueCaptured: false,
    });
  });

  it('captures ordinary text values only after explicit opt-in', () => {
    const classification = classifyField(textField, policy(true));

    expect(classification.captureValue).toBe(true);
    expect(textEditPayload(classification, 'retention')).toEqual({
      fieldKind: 'text',
      fieldType: 'text',
      filled: true,
      valueCaptured: true,
      value: 'retention',
    });
  });

  it('always excludes password, hidden, file and secret-like fields', () => {
    for (const descriptor of [
      { tagName: 'input', type: 'password', label: 'Password' },
      { tagName: 'input', type: 'hidden', name: 'csrf' },
      { tagName: 'input', type: 'file', name: 'attachment' },
      { tagName: 'input', type: 'text', autocomplete: 'one-time-code' },
      { tagName: 'input', type: 'text', autocomplete: 'cc-number' },
      { tagName: 'input', type: 'text', name: 'access_token' },
      { tagName: 'input', type: 'text', name: 'accessToken' },
      { tagName: 'input', type: 'text', name: 'apiKey' },
      { tagName: 'input', type: 'text', id: 'api-key' },
    ] satisfies FieldDescriptor[]) {
      expect(classifyField(descriptor, policy(true)).excluded).toBeDefined();
    }
  });

  it('excludes fields behind private ancestors and disabled selectors', () => {
    expect(classifyField(textField, { captureValues: true, redacted: true }).excluded).toBe(
      'redacted',
    );
    expect(classifyField(textField, { captureValues: true, disabled: true }).excluded).toBe(
      'disabled',
    );
  });

  it('keeps the action but not the value when the label looks sensitive', () => {
    const classification = classifyField(
      { tagName: 'input', type: 'text', label: 'API token' },
      policy(true),
    );

    expect(classification.excluded).toBeUndefined();
    expect(classification.captureValue).toBe(false);

    for (const label of ['Verification code', 'Security code', 'SMS code', 'Password']) {
      const hinted = classifyField({ tagName: 'input', type: 'text', label }, policy(true));
      expect(hinted.excluded).toBeUndefined();
      expect(hinted.captureValue).toBe(false);
    }
  });

  it('records checkbox and radio state without treating it as a text value', () => {
    const checkbox = classifyField(
      { tagName: 'input', type: 'checkbox', name: 'notify', label: 'Email alerts' },
      policy(true),
    );
    expect(checkbox.captureValue).toBe(false);
    expect(changePayload(checkbox, { checked: true })).toEqual({
      fieldKind: 'checkbox',
      fieldType: 'checkbox',
      valueCaptured: false,
      checked: true,
    });
  });

  it('includes select option labels only with opt-in', () => {
    const select = classifyField(
      { tagName: 'select', name: 'range', label: 'Date range' },
      policy(false),
    );
    expect(changePayload(select, { value: '30', optionLabel: 'Last 30 days' })).toEqual({
      fieldKind: 'select',
      fieldType: 'select',
      valueCaptured: false,
    });

    const optedIn = classifyField(
      { tagName: 'select', name: 'range', label: 'Date range' },
      policy(true),
    );
    expect(changePayload(optedIn, { value: '30', optionLabel: 'Last 30 days' })).toEqual({
      fieldKind: 'select',
      fieldType: 'select',
      valueCaptured: true,
      value: '30',
      optionLabel: 'Last 30 days',
    });
  });

  it('includes every selected option for a multiple select only with opt-in', () => {
    const select = classifyField(
      { tagName: 'select', name: 'categories', label: 'Categories' },
      policy(true),
    );
    expect(changePayload(select, { optionLabels: ['Retention', 'Churn'] })).toMatchObject({
      fieldKind: 'select',
      valueCaptured: true,
      optionLabels: ['Retention', 'Churn'],
    });
    expect(changePayload(select, { optionLabels: [] }).optionLabels).toEqual([]);

    const defaultPolicy = classifyField(
      { tagName: 'select', name: 'categories', label: 'Categories' },
      policy(false),
    );
    expect(changePayload(defaultPolicy, { optionLabels: ['Retention'] })).toEqual({
      fieldKind: 'select',
      fieldType: 'select',
      valueCaptured: false,
    });
  });

  it('normalizes and bounds option labels', () => {
    const select = classifyField(
      { tagName: 'select', name: 'categories', label: 'Categories' },
      policy(true),
    );
    const payload = changePayload(select, {
      optionLabels: ['  Retention\n  ', `${'x'.repeat(MAX_FIELD_VALUE_LENGTH + 10)}`],
    });
    expect(payload.optionLabels?.[0]).toBe('Retention');
    expect(payload.optionLabels?.[1]).toHaveLength(MAX_FIELD_VALUE_LENGTH);
  });

  it('recognizes submit controls and builds a bounded submit payload', () => {
    expect(isSubmitControlDescriptor({ tagName: 'button' })).toBe(true);
    expect(isSubmitControlDescriptor({ tagName: 'button', type: 'button' })).toBe(false);
    expect(isSubmitControlDescriptor({ tagName: 'input', type: 'submit' })).toBe(true);
    expect(submitPayload({ method: 'GET', action: '/search' }, 'Apply')).toEqual({
      method: 'get',
      action: '/search',
      submitterLabel: 'Apply',
    });
  });

  it('bounds long values', () => {
    const long = 'x'.repeat(MAX_FIELD_VALUE_LENGTH + 20);
    expect(boundedFieldValue(long)).toHaveLength(MAX_FIELD_VALUE_LENGTH);
    expect(boundedFieldValue('short')).toBe('short');
  });
});

describe('TextEditCoalescer', () => {
  it('coalesces a burst into one edit with the latest value', () => {
    const edits = new TextEditCoalescer();
    expect(edits.push('field-1', 'r', 10)).toBeUndefined();
    expect(edits.push('field-1', 're', 20)).toBeUndefined();
    expect(edits.push('field-1', 'ret', 30)).toBeUndefined();

    expect(edits.flush()).toEqual({
      key: 'field-1',
      firstAtMs: 10,
      lastAtMs: 30,
      value: 'ret',
    });
    expect(edits.hasPending).toBe(false);
  });

  it('commits the previous field before starting another one', () => {
    const edits = new TextEditCoalescer();
    edits.push('field-1', 'one', 10);

    expect(edits.push('field-2', 'two', 20)).toEqual({
      key: 'field-1',
      firstAtMs: 10,
      lastAtMs: 10,
      value: 'one',
    });
    expect(edits.flush()).toMatchObject({ key: 'field-2', value: 'two' });
  });

  it('commits at the maximum window even while the user keeps typing', () => {
    const edits = new TextEditCoalescer(1_000);
    edits.push('field-1', 'a', 0);
    edits.push('field-1', 'ab', 500);
    expect(edits.push('field-1', 'abc', 1_000)).toMatchObject({ value: 'abc' });
    expect(edits.hasPending).toBe(false);
  });

  it('flushes and clears pending state for stop and reset', () => {
    const edits = new TextEditCoalescer();
    edits.push('field-1', 'pending', 10);
    expect(edits.flush()?.value).toBe('pending');

    edits.push('field-1', 'discarded', 20);
    edits.clear();
    expect(edits.flush()).toBeUndefined();
  });
});
