/**
 * Form activity capture is deliberately semantic, not keystroke-level. These helpers
 * classify a field and build bounded payloads; the DOM wiring lives in `index.ts`.
 */

export type FormFieldKind = 'text' | 'textarea' | 'select' | 'checkbox' | 'radio';

export type FieldExclusion =
  | 'redacted'
  | 'disabled'
  | 'password'
  | 'hidden'
  | 'file'
  | 'sensitive'
  | 'unsupported';

export interface FieldDescriptor {
  tagName: string;
  type?: string | null;
  name?: string | null;
  id?: string | null;
  autocomplete?: string | null;
  label?: string | null;
  contentEditable?: boolean;
}

export interface FieldPolicy {
  /** Explicitly include supported, non-sensitive values. Defaults to false. */
  captureValues: boolean;
  /** The field or an ancestor matched a privacy redaction selector. */
  redacted?: boolean;
  /** The field or an ancestor matched a capture-disable selector. */
  disabled?: boolean;
}

export interface FieldClassification {
  kind: FormFieldKind | 'unsupported';
  inputType: string;
  /** Present when the field must not produce any activity event. */
  excluded?: FieldExclusion;
  /** True for fields whose value can be captured when policy allows it. */
  valueCapable: boolean;
  /** True only when this event may include the value. */
  captureValue: boolean;
}

export interface TextEditPayload {
  [key: string]: unknown;
  fieldKind: FormFieldKind;
  fieldType: string;
  filled: boolean;
  valueCaptured: boolean;
  value?: string;
}

export interface ChangePayload {
  [key: string]: unknown;
  fieldKind: FormFieldKind;
  fieldType: string;
  valueCaptured: boolean;
  checked?: boolean;
  value?: string;
  optionLabel?: string;
  /** Every selected option for a `<select multiple>`, in document order. */
  optionLabels?: string[];
}

export interface SubmitPayload {
  [key: string]: unknown;
  method?: string;
  action?: string;
  submitterLabel?: string;
}

export interface CoalescedTextEdit {
  key: string;
  firstAtMs: number;
  lastAtMs: number;
  value: string;
}

/** Long values are bounded so a single paste cannot bloat the manifest/report. */
export const MAX_FIELD_VALUE_LENGTH = 500;

const TEXT_INPUT_TYPES = new Set([
  'text',
  'search',
  'email',
  'url',
  'tel',
  'number',
  'date',
  'datetime-local',
  'month',
  'week',
  'time',
]);

const SENSITIVE_AUTOCOMPLETE = new Set([
  'current-password',
  'new-password',
  'one-time-code',
  'webauthn',
]);

// Matches token-like field names such as `api_key`, `accessToken`, `otp`, or `cardNumber`.
const SENSITIVE_TEXT =
  /(?:^|[^a-z0-9])(pass(?:word|code|phrase|wd)?|secret|token|api[-_\s]?key|auth(?:entication)?|credential|otp|one[-_\s]?time[-_\s]?code|verification[-_\s]?code|security[-_\s]?code|sms[-_\s]?code|recovery[-_\s]?code|backup[-_\s]?code|confirmation[-_\s]?code|2fa|mfa|pin|cvv|cvc|ssn|social[-_\s]?security|card[-_\s]?number|routing[-_\s]?number)(?:$|[^a-z0-9])/i;

function camelWords(value: string): string {
  return value.replace(/([a-z0-9])([A-Z])/g, '$1 $2');
}

export function boundedFieldValue(value: string): string {
  if (value.length <= MAX_FIELD_VALUE_LENGTH) return value;
  return `${value.slice(0, MAX_FIELD_VALUE_LENGTH - 1)}…`;
}

function normalizedType(type: string | null | undefined, tagName: string): string {
  if (tagName === 'select') return 'select';
  if (tagName === 'textarea') return 'textarea';
  return (type ?? 'text').trim().toLowerCase() || 'text';
}

function hasSensitiveAutocomplete(autocomplete: string | null | undefined): boolean {
  for (const token of autocomplete?.toLowerCase().split(/\s+/) ?? []) {
    if (!token) continue;
    if (SENSITIVE_AUTOCOMPLETE.has(token) || token.startsWith('cc-')) return true;
  }
  return false;
}

function hasSensitiveText(value: string | null | undefined): boolean {
  return value ? SENSITIVE_TEXT.test(camelWords(value)) : false;
}

export function isSensitiveFieldMetadata(descriptor: FieldDescriptor): boolean {
  return (
    hasSensitiveAutocomplete(descriptor.autocomplete) ||
    hasSensitiveText(descriptor.name) ||
    hasSensitiveText(descriptor.id)
  );
}

/**
 * Classify a field before recording anything. Password/hidden/file fields and fields
 * named or autocompleted like secrets never produce activity. A sensitive-looking
 * label (for example “API token”) still allows the action but never its value.
 */
export function classifyField(
  descriptor: FieldDescriptor,
  policy: FieldPolicy,
): FieldClassification {
  const tagName = descriptor.tagName.toLowerCase();
  const inputType = descriptor.contentEditable
    ? 'contenteditable'
    : normalizedType(descriptor.type, tagName);
  const excluded = (reason: FieldExclusion): FieldClassification => ({
    kind: 'unsupported',
    inputType,
    excluded: reason,
    valueCapable: false,
    captureValue: false,
  });

  if (policy.redacted) return excluded('redacted');
  if (policy.disabled) return excluded('disabled');

  if (tagName === 'input') {
    if (inputType === 'password') return excluded('password');
    if (inputType === 'hidden') return excluded('hidden');
    if (inputType === 'file') return excluded('file');
  }
  if (isSensitiveFieldMetadata(descriptor)) return excluded('sensitive');

  let kind: FormFieldKind | 'unsupported';
  if (descriptor.contentEditable || tagName === 'textarea') {
    kind = 'textarea';
  } else if (tagName === 'select') {
    kind = 'select';
  } else if (tagName === 'input' && (inputType === 'checkbox' || inputType === 'radio')) {
    kind = inputType;
  } else if (tagName === 'input' && TEXT_INPUT_TYPES.has(inputType)) {
    kind = 'text';
  } else {
    kind = 'unsupported';
  }

  if (kind === 'unsupported') return excluded('unsupported');

  const valueCapable = kind === 'text' || kind === 'textarea' || kind === 'select';
  const valueSensitiveHint = hasSensitiveText(descriptor.label);
  return {
    kind,
    inputType,
    valueCapable,
    captureValue: valueCapable && policy.captureValues && !valueSensitiveHint,
  };
}

export function isSubmitControlDescriptor(descriptor: FieldDescriptor): boolean {
  const tagName = descriptor.tagName.toLowerCase();
  const type = descriptor.type?.trim().toLowerCase() ?? '';
  return (
    (tagName === 'button' && (type === '' || type === 'submit')) ||
    (tagName === 'input' && (type === 'submit' || type === 'image'))
  );
}

function excerpt(value: string | null | undefined): string | undefined {
  const text = value?.replace(/\s+/g, ' ').trim();
  if (!text) return undefined;
  return text.length > 160 ? `${text.slice(0, 157)}…` : text;
}

function boundedLabel(value: string): string {
  return boundedFieldValue(value.replace(/\s+/g, ' ').trim());
}

/** Non-content and explicitly hidden descendants are never part of a label or excerpt. */
const HIDDEN_CONTENT_SELECTORS = [
  'script',
  'style',
  'template',
  'noscript',
  '[hidden]',
  '[aria-hidden="true"]',
  '[data-highlite-root]',
];

function removeMatches(root: Element, selectors: readonly string[]): void {
  for (const selector of selectors) {
    try {
      for (const node of root.querySelectorAll(selector)) node.remove();
    } catch {
      // A caller-supplied selector must never break capture.
    }
  }
}

function cleanClone(
  element: Element,
  privateSelectors: readonly string[],
  removeButtons: boolean,
): Element {
  const clone = element.cloneNode(true) as Element;
  // Capture the parallel list before any node is removed so indexes stay aligned.
  const copies = clone.querySelectorAll('*');
  removeMatches(clone, HIDDEN_CONTENT_SELECTORS);
  removeMatches(clone, privateSelectors);
  removeMatches(
    clone,
    removeButtons ? ['input', 'select', 'textarea', 'button'] : ['input', 'select', 'textarea'],
  );
  removeDisplayNoneDescendants(element, copies);
  return clone;
}

/** Keep CSS-hidden text out of the clone-based path as well as the `innerText` path. */
function removeDisplayNoneDescendants(original: Element, copies: NodeListOf<Element>): void {
  const originals = original.querySelectorAll('*');
  const count = Math.min(originals.length, copies.length);
  for (let index = 0; index < count; index += 1) {
    const source = originals[index];
    const copy = copies[index];
    if (!source || !copy || !source.isConnected) continue;
    const style = source.ownerDocument.defaultView?.getComputedStyle(source);
    if (style?.display === 'none') copy.remove();
  }
}

/**
 * Visible text for a target excerpt. Private, hidden, decorative, and embedded control
 * content is removed so an ancestor target cannot reveal a descendant marked private
 * or a value that happens to be rendered inside a control.
 */
function hasExcludedDescendant(
  element: Element,
  privateSelectors: readonly string[],
  removeButtons: boolean,
): boolean {
  const selectors = [
    ...HIDDEN_CONTENT_SELECTORS,
    ...privateSelectors,
    'input',
    'select',
    'textarea',
    ...(removeButtons ? ['button'] : []),
  ];
  return selectors.some((selector) => {
    try {
      return element.querySelector(selector) !== null;
    } catch {
      return false;
    }
  });
}

function renderedText(element: Element): string | null | undefined {
  // `innerText` respects CSS hidden descendants when there is nothing to sanitize.
  return element instanceof HTMLElement ? element.innerText : element.textContent;
}

export function readableTextExcerpt(
  element: Element,
  privateSelectors: readonly string[] = [],
): string | undefined {
  if (!hasExcludedDescendant(element, privateSelectors, false)) {
    return excerpt(renderedText(element));
  }
  return excerpt(cleanClone(element, privateSelectors, false).textContent);
}

/** Text that belongs to a label, excluding decorative and embedded form-control content. */
function labelText(
  element: Element | null,
  privateSelectors: readonly string[] = [],
): string | undefined {
  if (!element) return undefined;
  if (!hasExcludedDescendant(element, privateSelectors, true)) {
    return excerpt(renderedText(element));
  }
  return excerpt(cleanClone(element, privateSelectors, true).textContent);
}

export function contentEditableHost(element: Element): HTMLElement | undefined {
  const host = element.closest(
    '[contenteditable=""], [contenteditable="true"], [contenteditable="plaintext-only"]',
  );
  return host instanceof HTMLElement ? host : undefined;
}

export function isFieldElement(element: Element): boolean {
  return element.matches('input, textarea, select') || contentEditableHost(element) !== undefined;
}

export interface AccessibleLabelOptions {
  /** Selectors whose subtree is private and must not contribute visible text. */
  privateSelectors?: readonly string[];
}

/** Associated label text, aria-labelledby, aria-label, or another human-readable hint. */
export function accessibleLabel(
  element: Element,
  options: AccessibleLabelOptions = {},
): string | undefined {
  const privateSelectors = options.privateSelectors ?? [];
  const labelledBy = element.getAttribute('aria-labelledby');
  if (labelledBy) {
    const text = labelledBy
      .split(/\s+/)
      .map((id) => labelText(element.ownerDocument.getElementById(id), privateSelectors) ?? '')
      .join(' ');
    const label = excerpt(text);
    if (label) return label;
  }

  const aria = excerpt(element.getAttribute('aria-label'));
  if (aria) return aria;

  const tagName = element.tagName.toLowerCase();
  if (element.id && ['input', 'textarea', 'select', 'button'].includes(tagName)) {
    try {
      const label = element.ownerDocument.querySelector(`label[for="${CSS.escape(element.id)}"]`);
      const text = labelText(label, privateSelectors);
      if (text) return text;
    } catch {
      // An invalid selector must never break capture.
    }
  }

  const wrapper = element.closest('label');
  const wrapperText = labelText(wrapper, privateSelectors);
  if (wrapperText) return wrapperText;

  if (element instanceof HTMLLabelElement) {
    const ownText = labelText(element, privateSelectors);
    if (ownText) return ownText;
  }

  const inputType = (element.getAttribute('type') ?? '').toLowerCase();
  if (
    tagName === 'button' ||
    (tagName === 'input' && ['submit', 'button', 'reset'].includes(inputType))
  ) {
    const ownText =
      readableTextExcerpt(element, privateSelectors) ?? excerpt(element.getAttribute('value'));
    if (ownText) return ownText;
  }

  const hints = [
    element.getAttribute('alt'),
    element.getAttribute('title'),
    element.getAttribute('placeholder'),
  ];
  for (const hint of hints) {
    const text = excerpt(hint);
    if (text) return text;
  }

  if (tagName === 'form') {
    const name = excerpt(element.getAttribute('name'));
    if (name) return name;
  }
  return undefined;
}

export function fieldDescriptor(
  element: Element,
  options: AccessibleLabelOptions = {},
): FieldDescriptor | undefined {
  const editable = contentEditableHost(element);
  if (editable) {
    return {
      tagName: editable.tagName,
      contentEditable: true,
      id: editable.id || null,
      autocomplete: editable.getAttribute('autocomplete'),
      label: accessibleLabel(editable, options),
    };
  }
  const tagName = element.tagName.toLowerCase();
  if (!['input', 'textarea', 'select'].includes(tagName)) return undefined;
  return {
    tagName,
    type: element.getAttribute('type'),
    name: element.getAttribute('name'),
    id: element.id || null,
    autocomplete: element.getAttribute('autocomplete'),
    label: accessibleLabel(element, options),
  };
}

export function textEditPayload(
  classification: FieldClassification,
  text: string,
): TextEditPayload {
  const filled = text.length > 0;
  return {
    fieldKind: classification.kind === 'unsupported' ? 'text' : classification.kind,
    fieldType: classification.inputType,
    filled,
    valueCaptured: classification.captureValue,
    ...(classification.captureValue ? { value: boundedFieldValue(text) } : {}),
  };
}

export function changePayload(
  classification: FieldClassification,
  state: {
    checked?: boolean;
    value?: string;
    optionLabel?: string;
    optionLabels?: readonly string[];
  },
): ChangePayload {
  const fieldKind = classification.kind === 'unsupported' ? 'text' : classification.kind;
  if (classification.kind === 'checkbox' || classification.kind === 'radio') {
    return {
      fieldKind,
      fieldType: classification.inputType,
      valueCaptured: false,
      checked: state.checked ?? false,
    };
  }
  const optionLabels = classification.captureValue
    ? state.optionLabels?.map(boundedLabel).filter(Boolean)
    : undefined;
  return {
    fieldKind,
    fieldType: classification.inputType,
    valueCaptured: classification.captureValue,
    ...(classification.captureValue && state.value !== undefined
      ? { value: boundedFieldValue(state.value) }
      : {}),
    ...(classification.captureValue && state.optionLabel
      ? { optionLabel: boundedLabel(state.optionLabel) }
      : {}),
    ...(optionLabels ? { optionLabels } : {}),
  };
}

export function submitPayload(
  form: { method?: string; action?: string },
  submitterLabel: string | undefined,
): SubmitPayload {
  return {
    ...(form.method ? { method: form.method.toLowerCase() } : {}),
    ...(form.action ? { action: form.action } : {}),
    ...(submitterLabel ? { submitterLabel } : {}),
  };
}

/** Text fields are sampled, never logged keystroke by keystroke. */
export class TextEditCoalescer {
  readonly #maxWindowMs: number;
  #pending: CoalescedTextEdit | undefined;

  constructor(maxWindowMs = 2_000) {
    this.#maxWindowMs = maxWindowMs;
  }

  get hasPending(): boolean {
    return this.#pending !== undefined;
  }

  /**
   * Add a sample. Returns the previous edit when it must be committed: the user moved
   * to another field, or the edit has been open for the maximum window.
   */
  push(key: string, value: string, atMs: number): CoalescedTextEdit | undefined {
    const pending = this.#pending;
    if (!pending) {
      this.#pending = { key, value, firstAtMs: atMs, lastAtMs: atMs };
      return undefined;
    }
    if (pending.key !== key) {
      this.#pending = { key, value, firstAtMs: atMs, lastAtMs: atMs };
      return { ...pending };
    }
    pending.value = value;
    pending.lastAtMs = atMs;
    if (atMs - pending.firstAtMs >= this.#maxWindowMs) {
      this.#pending = undefined;
      return { ...pending };
    }
    return undefined;
  }

  flush(): CoalescedTextEdit | undefined {
    const pending = this.#pending;
    this.#pending = undefined;
    return pending ? { ...pending } : undefined;
  }

  clear(): void {
    this.#pending = undefined;
  }
}
