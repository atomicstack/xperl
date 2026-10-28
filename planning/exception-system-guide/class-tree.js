/* Class ancestry is the tree. Diagnostic children in this view are catalog
 * members of a class, not the children of a runtime diagnostic instance. */
class DiagnosticTree {
    constructor(data) {
        this.tree = document.getElementById('tree');
        this.details = document.getElementById('details');
        this.sourceRoot = data.source_root;
        this.search = document.getElementById('search');
        this.filter = document.getElementById('filter');
        this.showEmpty = document.getElementById('empty');
        this.nodes = new Map();
        this.expanded = new Set();
        this.selected = null;
        this.filtering = false;
        this.savedExpansion = null;
        this.buildModel(data);
        this.setDefaultExpansion();
        for (const root of this.roots) this.tree.append(this.buildElement(root, 1));
        this.bindControls();
        this.updateFilter();
    }

    makeElement(tag, text, className) {
        const element = document.createElement(tag);
        if (text !== undefined) element.textContent = text;
        if (className) element.className = className;
        return element;
    }

    buildModel(data) {
        for (const record of data.classes) {
            const name = record.class;
            const prefix = record.parent + '::';
            this.nodes.set(name, {
                id: name, kind: 'class', record, children: [],
                label: name.startsWith(prefix) ? name.slice(prefix.length) : name,
                parent: record.parent || null, className: name,
            });
        }
        this.roots = [];
        for (const node of this.nodes.values()) {
            if (node.parent) this.nodes.get(node.parent).children.push(node);
            else this.roots.push(node);
        }
        for (const record of data.diagnostics) {
            const parent = this.nodes.get(record.recommendation);
            if (!parent) continue;
            const node = {
                id: 'diagnostic:' + record.code, kind: 'diagnostic', record,
                label: record.code, parent: parent.id, className: parent.id,
                children: [],
            };
            node.searchText = [node.label, node.className, record.analysis_categories,
                record.platform, record.rationale,
                ...(record.source_files || []),
                ...(record.english_templates || []).map(entry => entry.text)].join(' ').toLowerCase();
            this.nodes.set(node.id, node);
            parent.children.push(node);
        }
        // Keep class branches before their directly assigned diagnostic codes.
        for (const node of this.nodes.values()) {
            node.children.sort((a, b) =>
                (a.kind === b.kind ? 0 : a.kind === 'class' ? -1 : 1)
                || (a.label < b.label ? -1 : a.label > b.label ? 1 : 0));
        }
    }

    setDefaultExpansion() {
        this.expanded = new Set(['XPerl::DiagGroup', 'XPerl::Diagnostic',
            'XPerl::Diagnostic::Error', 'XPerl::Diagnostic::Warning']);
    }

    badges(node, destination) {
        for (const [field, label] of [['is_internal', 'internal'],
            ['is_panic', 'panic'], ['is_render', 'render']]) {
            if (node.record[field] === '1') {
                destination.append(this.makeElement('span', label, 'badge ' + label));
            }
        }
        const proposed = node.kind === 'class' ? !node.record.registered
            : node.record.recommendation !== node.record.current_default_class;
        if (proposed) destination.append(this.makeElement('span', 'proposed', 'badge proposal'));
    }

    buildElement(node, level) {
        const item = this.makeElement('li', undefined, node.kind);
        item.setAttribute('role', 'treeitem');
        item.setAttribute('aria-level', level);
        item.setAttribute('aria-selected', 'false');
        item.tabIndex = -1;
        item.dataset.nodeId = node.id;
        const row = this.makeElement('div', undefined, 'tree-row');
        const family = node.className;
        const category = node.record.is_internal === '1'
            || /^XPerl::Diagnostic::Error::Internal(?:$|::)/.test(family) ? 'internal'
            : /^XPerl::Diagnostic::Warning(?:$|::)/.test(family) ? 'warning'
            : /^XPerl::Diagnostic::Error(?:$|::)/.test(family) ? 'error' : 'note';
        row.classList.add('category-' + category);
        if (node.children.length) {
            const toggle = this.makeElement('button', undefined, 'toggle');
            toggle.type = 'button';
            toggle.tabIndex = -1;
            toggle.setAttribute('aria-label', 'Toggle ' + node.label);
            row.append(toggle);
        } else {
            row.append(this.makeElement('span', '', 'spacer'));
        }
        if (node.kind === 'diagnostic') {
            const label = this.makeElement('div', undefined, 'diagnostic-label');
            label.append(this.makeElement('span', node.label, 'name'));
            const templates = node.record.english_templates || [];
            const preview = templates.find(entry => entry.selectors.every(pair => pair[1] === '*')) || templates[0];
            if (preview) {
                const prefix = templates.length > 1 ? `${templates.length} cases · ` : '';
                const text = this.makeElement('span', prefix + preview.text, 'template-preview');
                text.title = preview.text;
                label.append(text);
            } else {
                label.append(this.makeElement('span', 'No fixed English template', 'template-preview'));
            }
            const files = node.record.source_files || [];
            const locations = node.record.source_locations || {};
            label.append(this.makeElement('span', files.length
                ? 'Files: ' + files.map(file => file + (locations[file]?.length
                    ? ':' + locations[file].join(',') : '')).join(' · ')
                : 'No source references recorded', 'source-preview'));
            row.append(label);
        } else {
            row.append(this.makeElement('span', node.label, 'name'));
        }
        if (node.kind === 'class') {
            node.count = this.makeElement('span', '', 'count');
            row.append(node.count);
        }
        this.badges(node, row);
        item.append(row);
        node.element = item;
        if (node.children.length) {
            node.group = this.makeElement('ul');
            node.group.setAttribute('role', 'group');
            for (const child of node.children) node.group.append(this.buildElement(child, level + 1));
            item.append(node.group);
            this.refreshExpansion(node);
        }
        return item;
    }

    refreshExpansion(node) {
        if (!node.group) return;
        const open = this.expanded.has(node.id);
        node.element.setAttribute('aria-expanded', String(open));
        node.group.hidden = !open;
    }

    toggle(node, open = !this.expanded.has(node.id)) {
        if (!node.group) return;
        if (open) this.expanded.add(node.id);
        else this.expanded.delete(node.id);
        this.refreshExpansion(node);
        // A collapsed branch must not leave the keyboard target hidden below it.
        if (this.selected && this.selected.element.closest('[hidden]')) this.select(node, false);
    }

    matches(node, terms, flag) {
        if (flag !== 'all' && node.record['is_' + flag] !== '1') return false;
        return terms.every(term => node.searchText.includes(term));
    }

    updateFilter() {
        const terms = this.search.value.trim().toLowerCase().split(/\s+/).filter(Boolean);
        const flag = this.filter.value;
        const searching = terms.length > 0 || flag !== 'all';
        if (searching && !this.filtering) this.savedExpansion = new Set(this.expanded);
        if (!searching && this.filtering) this.expanded = this.savedExpansion;
        this.filtering = searching;
        const visit = node => {
            if (node.kind === 'diagnostic') {
                node.matches = this.matches(node, terms, flag) ? 1 : 0;
                node.element.hidden = !node.matches;
                return node.matches;
            }
            node.matches = node.children.reduce((sum, child) => sum + visit(child), 0);
            const emptyMatch = this.showEmpty.checked && flag === 'all'
                && terms.every(term => node.className.toLowerCase().includes(term));
            const hasVisibleChild = node.children.some(child => !child.element.hidden);
            node.element.hidden = !node.matches && !emptyMatch && !hasVisibleChild;
            node.count.textContent = String(node.matches);
            node.count.title = 'Matching diagnostic definitions in this branch';
            if (searching && !node.element.hidden && node.group) this.expanded.add(node.id);
            this.refreshExpansion(node);
            return node.matches;
        };
        const count = this.roots.reduce((sum, root) => sum + visit(root), 0);
        const classCount = [...this.nodes.values()].filter(node =>
            node.kind === 'class' && !node.element.hidden).length;
        document.getElementById('counts').textContent =
            `${count.toLocaleString()} diagnostic definitions · ${classCount} classes`;
        document.getElementById('no-results').hidden = classCount > 0;
        if (!this.selected || this.selected.element.closest('[hidden]')) {
            const first = this.visibleItems()[0];
            if (first) this.select(this.nodes.get(first.dataset.nodeId), false);
            else {
                if (this.selected) {
                    this.selected.element.tabIndex = -1;
                    this.selected.element.setAttribute('aria-selected', 'false');
                }
                this.selected = null;
                this.details.replaceChildren(this.makeElement('h2', 'No matching item'));
            }
        }
    }

    visibleItems() {
        return [...this.tree.querySelectorAll('[role=treeitem]')]
            .filter(item => !item.closest('[hidden]'));
    }

    select(node, focus = true) {
        if (this.selected) {
            this.selected.element.tabIndex = -1;
            this.selected.element.setAttribute('aria-selected', 'false');
        }
        this.selected = node;
        node.element.tabIndex = 0;
        node.element.setAttribute('aria-selected', 'true');
        if (focus) node.element.focus({preventScroll: false});
        this.showDetails(node);
    }

    showDetails(node) {
        const record = node.record;
        this.details.replaceChildren(this.makeElement('h2', node.label));
        const badges = this.makeElement('div');
        this.badges(node, badges);
        this.details.append(badges);
        if (node.kind === 'diagnostic') this.showSourceFiles(record);
        const list = this.makeElement('dl');
        const field = (label, value) => {
            if (value === undefined || value === '') return;
            list.append(this.makeElement('dt', label), this.makeElement('dd', value));
        };
        if (node.kind === 'class') {
            field('Full class', node.className);
            field('Parent', record.parent || 'None');
            field('Registration', record.registered ? 'Registered runtime class' : 'Proposed class');
            field('Diagnostic containment', record.leaf_only === '1'
                ? 'Leaf-only: instances cannot own diagnostic children' : 'Instances may own diagnostic children');
            field('Warning category', record.warning_category === '-' ? 'No class category' : record.warning_category);
            field('Direct definitions', node.children.filter(child => child.kind === 'diagnostic').length);
            field('Matching definitions in branch', node.matches);
        } else {
            field('Code', record.code);
            field('Number', record.number);
            field('Review class', record.recommendation);
            field('Current runtime class', record.current_default_class);
            field('Previous default class', record.previous_default_class);
            field('Proposed parents', record.recommended_parents);
            field('Related warning categories', record.related_warning_categories);
            field('Related Python categories', record.related_python_categories);
            field('Review status', record.review_status);
            field('Platform', record.platform);
            field('Rationale', record.rationale);
            if (record.is_render === '1') {
                field('Render-only', 'Formats supplied values; does not construct or deliver a diagnostic instance.');
            }
        }
        this.details.append(list);
        if (node.kind === 'diagnostic') {
            this.showSelectors(record);
            this.showWords(record);
            this.showTemplates(record);
        }
        if (node.kind === 'diagnostic' && record.analysis_categories) {
            this.details.append(this.makeElement('h3', 'Tags'));
            const tags = this.makeElement('ul', undefined, 'tags');
            for (const tag of record.analysis_categories.split('; ')) tags.append(this.makeElement('li', tag));
            this.details.append(tags);
        }
    }

    showSourceFiles(record) {
        const files = record.source_files || [];
        this.details.append(this.makeElement('h3', `Source references (${files.length})`));
        if (!files.length) {
            this.details.append(this.makeElement('p',
                'No references found in the scanned core and extension sources. This is not proof that the entry is unused.'));
            return;
        }
        const list = this.makeElement('ul', undefined, 'source-files');
        for (const file of files) {
            const item = this.makeElement('li');
            const link = this.makeElement('a', file);
            link.href = this.sourceRoot + '/' + file.split('/').map(encodeURIComponent).join('/');
            item.append(link);
            list.append(item);
        }
        this.details.append(list);
        const contexts = record.source_contexts || [];
        for (const context of contexts) {
            const section = this.makeElement('details', undefined, 'source-context');
            section.open = contexts.length <= 3 || context === contexts[0];
            const owners = (context.owners || []).map(owner => {
                if (owner.kind === 'macro') return '#define ' + owner.name;
                if (owner.kind === 'XS function') return 'XS: ' + owner.name + '()';
                if (owner.kind === 'function') return owner.name + '()';
                return 'enclosing function not determined';
            });
            section.append(this.makeElement('summary',
                context.file + ':' + context.matches.join(', ') + ' — ' + owners.join(', ')));
            const code = this.makeElement('pre');
            const matches = new Set(context.matches);
            context.lines.forEach((text, index) => {
                const number = context.start + index;
                const line = this.makeElement('span', undefined,
                    'source-line' + (matches.has(number) ? ' matched-line' : ''));
                line.append(this.makeElement('span', String(number), 'line-number'));
                line.append(this.makeElement('span', text || ' ', 'source-text'));
                code.append(line);
            });
            section.append(code);
            this.details.append(section);
        }
        this.details.append(this.makeElement('p',
            'Highlighted lines are references, with three preceding and three following lines. Nearby windows are merged. Function names are inferred from source without preprocessing. References include emitters, forwarding APIs, framework checks and extension test fixtures.'));
    }

    showSelectors(record) {
        const selectors = record.selectors || [];
        this.details.append(this.makeElement('h3', `Selectors (${selectors.length})`));
        if (!selectors.length) {
            this.details.append(this.makeElement('p', 'This diagnostic has no selectors.'));
            return;
        }
        for (const selector of selectors) {
            const section = this.makeElement('section', undefined, 'template-case');
            section.append(this.makeElement('h4', selector.name));
            if (selector.source !== selector.name) {
                section.append(this.makeElement('p', 'Source parameter: ' + selector.source));
            }
            if (selector.plural) {
                section.append(this.makeElement('p', selector.plural +
                    ' plural: standard categories and exact numbers used across all languages.'));
            }
            const values = this.makeElement('ul', undefined, 'tags');
            for (const value of selector.values) values.append(this.makeElement('li', value));
            values.append(this.makeElement('li', '* (any)'));
            section.append(values);
            if (selector.conditional) {
                section.append(this.makeElement('p',
                    'Values shown are the union of conditional domains; availability depends on preceding selectors.'));
            }
            this.details.append(section);
        }
        this.details.append(this.makeElement('p',
            '* matches any value. These are the allowed selector domains across all languages, not just cases used by English templates.'));
    }

    showWords(record) {
        const bindings = record.word_bindings || [];
        if (!bindings.length) return;
        this.details.append(this.makeElement('h3', `Operation words (${bindings.length})`));
        this.details.append(this.makeElement('p',
            'These parameters keep original display text and separate operation identity. Rendering substitutes a language-owned form in a temporary view. Word identity does not itself consume a selector.'));
        for (const binding of bindings) {
            const section = this.makeElement('section', undefined, 'template-case');
            section.append(this.makeElement('h4', `%{${binding.name}}`));
            section.append(this.makeElement('p', `Identity source: ${binding.source}`));
            if (binding.assert_unknown) {
                section.append(this.makeElement('p',
                    'Closed source domain: unknown identities assert in debugging builds and preserve the supplied text in release builds.'));
            }
            const domain = this.makeElement('details');
            domain.append(this.makeElement('summary', `Audited domain: ${binding.operations.length} operation identities`));
            domain.append(this.makeElement('p', binding.operations.join(', ')));
            section.append(domain);
            for (const rule of binding.rules) {
                let text = `${rule.language}: rule ${rule.name}, form ${rule.form}`;
                const outputs = Object.entries(rule.select).map(([name, value]) =>
                    `${binding.selectors[name]} from tag ${value.tag} (fallback ${value.fallback})`);
                if (outputs.length) text += '; ' + outputs.join('; ');
                if (rule.example) text += `; e.g. ${rule.example.operation} → ${rule.example.text}`;
                section.append(this.makeElement('p', text));
            }
            this.details.append(section);
        }
    }

    showTemplates(record) {
        const templates = record.english_templates || [];
        this.details.append(this.makeElement('h3', `English templates (${templates.length})`));
        if (!templates.length) {
            this.details.append(this.makeElement('p',
                'No fixed English template. This entry accepts or forwards a message supplied at runtime.'));
            return;
        }
        const input = this.makeElement('input');
        input.type = 'search';
        input.placeholder = 'Filter template text or selector cases';
        input.setAttribute('aria-label', 'Filter English template cases');
        if (templates.length > 1) this.details.append(input);
        const entries = templates.map(entry => {
            const section = this.makeElement('section', undefined, 'template-case');
            const selector = entry.selectors.map(([name, value]) => `${name}=${value}`).join(', ');
            section.append(this.makeElement('div', selector || 'No selector', 'selector-case'));
            section.append(this.makeElement('pre', entry.text));
            this.details.append(section);
            return {section, search: (selector + ' ' + entry.text).toLowerCase()};
        });
        input.addEventListener('input', () => {
            const query = input.value.trim().toLowerCase();
            for (const entry of entries) entry.section.hidden = !entry.search.includes(query);
        });
    }

    keydown(event) {
        const element = event.target.closest('[role=treeitem]');
        if (!element) return;
        const node = this.nodes.get(element.dataset.nodeId);
        const items = this.visibleItems();
        const index = items.indexOf(element);
        let target;
        switch (event.key) {
            case 'ArrowDown': target = items[index + 1]; break;
            case 'ArrowUp': target = items[index - 1]; break;
            case 'Home': target = items[0]; break;
            case 'End': target = items[items.length - 1]; break;
            case 'ArrowRight':
                if (!this.expanded.has(node.id)) this.toggle(node, true);
                else if (node.group) target = node.children.find(child => !child.element.hidden)?.element;
                break;
            case 'ArrowLeft':
                if (node.group && this.expanded.has(node.id)) this.toggle(node, false);
                else if (node.parent) target = this.nodes.get(node.parent).element;
                break;
            case 'Enter': case ' ': this.toggle(node); break;
            default: return;
        }
        event.preventDefault();
        if (target) this.select(this.nodes.get(target.dataset.nodeId));
    }

    bindControls() {
        this.search.addEventListener('input', () => this.updateFilter());
        this.filter.addEventListener('change', () => this.updateFilter());
        this.showEmpty.addEventListener('change', () => this.updateFilter());
        this.tree.addEventListener('keydown', event => this.keydown(event));
        this.tree.addEventListener('click', event => {
            const row = event.target.closest('.tree-row');
            if (!row) return;
            const node = this.nodes.get(row.parentElement.dataset.nodeId);
            this.select(node);
            if (event.target.closest('.toggle')) this.toggle(node);
        });
        this.tree.addEventListener('dblclick', event => {
            const row = event.target.closest('.tree-row');
            if (row && !event.target.closest('.toggle')) this.toggle(this.nodes.get(row.parentElement.dataset.nodeId));
        });
        document.getElementById('expand').addEventListener('click', () => {
            for (const node of this.nodes.values()) if (node.group) this.toggle(node, true);
        });
        document.getElementById('collapse').addEventListener('click', () => {
            for (const node of this.nodes.values()) if (node.group) this.toggle(node, false);
        });
        document.getElementById('reset').addEventListener('click', () => {
            this.search.value = '';
            this.filter.value = 'all';
            this.showEmpty.checked = false;
            this.filtering = false;
            this.savedExpansion = null;
            this.setDefaultExpansion();
            this.updateFilter();
            this.select(this.roots[0], false);
        });
    }
}

new DiagnosticTree(JSON.parse(document.getElementById('tree-data').textContent));
