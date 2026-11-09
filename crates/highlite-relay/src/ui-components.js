// Framework-free wizard controller. Forms remain owned by their calling workflow.
(() => {
  class Wizard {
    constructor(root, options = {}) {
      this.root = root;
      this.steps = [...root.querySelectorAll('[data-wizard-step]')];
      this.progress = root.querySelector('.wizard-progress');
      this.index = 0;
      this.editMode = false;
      this.busy = false;
      this.onStep = options.onStep || (() => {});
      this.beforeAdvance = options.beforeAdvance || (() => true);
      this.activeSteps = this.steps.filter((step) => !step.hasAttribute('data-wizard-skip'));
      this.isFirst = true;
      this.isLast = true;
      root.addEventListener('click', (event) => {
        const button = event.target.closest('[data-wizard-action]');
        if (!button || !root.contains(button) || button.disabled || this.busy) return;
        if (button.dataset.wizardAction === 'back') this.back();
        if (button.dataset.wizardAction === 'continue') this.next();
      });
      root.addEventListener('keydown', (event) => {
        if (event.key !== 'Enter' || event.target.matches('textarea,button,select')) return;
        if (!event.target.matches('input')) return;
        event.preventDefault();
        if (this.busy) return;
        if (!this.editMode && !this.isLast) this.next();
        else this.validate(this.activeSteps);
      });
      this.render();
    }

    controls(step) {
      if (step.hasAttribute('data-wizard-skip')) return [];
      return [...step.querySelectorAll('input,select,textarea')].filter(
        (field) =>
          !field.disabled &&
          !field.matches('[data-wizard-skip]') &&
          !field.closest('[data-wizard-skip]') &&
          !field.matches('[hidden]') &&
          !field.closest('[hidden]:not([data-wizard-step])'),
      );
    }

    focusInvalid(step, field) {
      const activeIndex = this.activeSteps.indexOf(step);
      if (activeIndex < 0) return;
      step.hidden = false;
      this.index = activeIndex;
      const disclosure = field.closest('details');
      if (disclosure) disclosure.open = true;
      this.render();
      field.focus();
      field.reportValidity();
    }

    validate(steps) {
      for (const step of steps) {
        for (const field of this.controls(step)) {
          if (!field.checkValidity()) {
            this.focusInvalid(step, field);
            return false;
          }
        }
      }
      return true;
    }

    goTo(index, focus = true) {
      if (this.busy || index < 0 || index >= this.activeSteps.length) return false;
      if (index > this.index && !this.beforeAdvance(this.index, index)) return false;
      this.index = index;
      this.render(focus);
      return true;
    }

    next() {
      if (this.isLast || !this.validate([this.activeSteps[this.index]])) return false;
      return this.goTo(this.index + 1);
    }

    back() {
      return this.goTo(Math.max(0, this.index - 1));
    }
    showAll() {
      this.editMode = true;
      this.render();
    }
    startWizard() {
      this.editMode = false;
      this.index = 0;
      this.busy = false;
      this.activeSteps = this.steps.filter((step) => !step.hasAttribute('data-wizard-skip'));
      this.render();
    }
    setBusy(value) {
      this.busy = Boolean(value);
      this.render();
    }

    render(focus = false) {
      this.activeSteps = this.steps.filter((step) => !step.hasAttribute('data-wizard-skip'));
      this.index = Math.min(Math.max(0, this.index), Math.max(0, this.activeSteps.length - 1));
      this.isFirst = this.index <= 0;
      this.isLast = this.activeSteps.length === 0 || this.index >= this.activeSteps.length - 1;
      const currentStep = this.activeSteps[this.index];
      this.steps.forEach((step) => {
        step.hidden =
          step.hasAttribute('data-wizard-skip') || (!this.editMode && step !== currentStep);
      });
      if (this.progress) {
        this.progress.hidden = this.editMode;
        this.progress.replaceChildren();
        this.activeSteps.forEach((step, index) => {
          const item = document.createElement('li');
          const button = document.createElement('button');
          button.type = 'button';
          button.textContent = step.dataset.stepLabel || `Step ${index + 1}`;
          button.setAttribute('aria-current', index === this.index ? 'step' : 'false');
          item.classList.toggle('completed', index < this.index);
          button.disabled = this.busy;
          button.addEventListener('click', () => {
            if (index <= this.index || this.validate(this.activeSteps.slice(this.index, index)))
              this.goTo(index);
          });
          item.append(button);
          this.progress.append(item);
        });
      }
      this.root.querySelectorAll('[data-wizard-action="back"]').forEach((button) => {
        button.hidden = this.editMode || this.isFirst;
        button.disabled = this.busy;
      });
      this.root.querySelectorAll('[data-wizard-action="continue"]').forEach((button) => {
        button.hidden = this.editMode || this.isLast;
        button.disabled = this.busy;
      });
      this.root.querySelectorAll('[data-wizard-save]').forEach((button) => {
        button.hidden = !this.editMode && !this.isLast;
        button.disabled = this.busy;
      });
      this.root.querySelectorAll('[data-wizard-choice]').forEach((element) => {
        element.hidden =
          this.editMode ||
          (element.matches('[data-wizard-step]') && element !== currentStep) ||
          element.hasAttribute('data-wizard-skip');
      });
      if (focus) {
        const heading = currentStep?.querySelector('h2, h3');
        heading?.focus();
      }
      this.onStep(this.index, this.editMode, this.busy, this.isLast, currentStep);
    }
  }

  function createViewNavigation(options) {
    const views = ['sessions', 'recipes', 'providers'];
    let authenticated = false;
    let current = null;
    const hashView = () => {
      const value = location.hash.slice(1);
      return views.includes(value) ? value : 'sessions';
    };
    const render = (view, focus = false) => {
      if (!authenticated) return;
      if (options.canLeave && !options.canLeave(current, view)) {
        history.replaceState(
          null,
          '',
          `${location.pathname}${location.search}#${current || 'sessions'}`,
        );
        return;
      }
      const previous = current;
      current = view;
      options.onChange(view, previous, focus);
    };
    const navigate = (view) => {
      if (!views.includes(view) || !authenticated) return;
      if (options.canLeave && !options.canLeave(current, view)) return;
      if (location.hash !== `#${view}`) location.hash = view;
      else render(view, true);
    };
    window.addEventListener('hashchange', () => {
      if (!authenticated) return;
      const view = hashView();
      if (location.hash !== `#${view}`)
        history.replaceState(null, '', `${location.pathname}${location.search}#${view}`);
      render(view, true);
    });
    return {
      activate() {
        authenticated = true;
        const view = hashView();
        if (location.hash !== `#${view}`)
          history.replaceState(null, '', `${location.pathname}${location.search}#${view}`);
        render(view, false);
      },
      deactivate() {
        authenticated = false;
        current = null;
      },
      navigate,
      get current() {
        return current;
      },
    };
  }

  window.HighliteUI = Object.freeze({
    Wizard,
    createWizard: (root, options) => new Wizard(root, options),
    createViewNavigation,
  });
})();
