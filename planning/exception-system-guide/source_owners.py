"""Infer enclosing definitions for source review without preprocessing C/XS."""

from bisect import bisect_right
import re


NONCODE = re.compile(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|/\*.*?\*/|//[^\n]*', re.S)
TOKEN = re.compile(r'[A-Za-z_]\w*|::|[^\s]')
CONTROL = {'if', 'for', 'while', 'switch', 'catch', 'sizeof', 'alignof', '_Alignof', 'decltype'}
WRAPPERS = {'PP', 'PP_wrapped', 'XS', 'XS_INTERNAL', 'XS_EXTERNAL', 'XS_EUPXS'}
ATTRIBUTES = {'__attribute__', '__declspec', 'noexcept'}
QUALIFIERS = {'const', 'volatile', 'override', 'final', 'PERL_UNUSED_DECL'}


def blank(match):
    """Keep offsets and physical line boundaries while masking noncode."""
    return re.sub(r'[^\n]', ' ', match.group())


def signature(tokens, closing, parentheses):
    """Recognize a declarator immediately before a body, including PP/XS wrappers."""
    while closing >= 0 and tokens[closing].group() in QUALIFIERS:
        closing -= 1
    while closing >= 0 and tokens[closing].group() == ')':
        opening = parentheses.get(closing)
        if opening is None or opening == 0:
            return None
        name_index = opening - 1
        name = tokens[name_index].group()
        if name in ATTRIBUTES:
            closing = opening - 2
            continue
        if name in CONTROL or not re.fullmatch(r'[A-Za-z_]\w*', name):
            return None
        if name in WRAPPERS:
            arguments = tokens[opening + 1:closing]
            if name == 'PP_wrapped' and len(arguments) > 1 and arguments[1].group() == ',':
                arguments = arguments[:1]
            if len(arguments) != 1 or not re.fullmatch(r'[A-Za-z_]\w*', arguments[0].group()):
                return None
            return arguments[0].group(), arguments[0].start()
        start = name_index
        while start >= 2 and tokens[start - 1].group() == '::':
            start -= 2
        return ''.join(token.group() for token in tokens[start:name_index + 1]), tokens[start].start()
    return None


def definition_index(text, filename):
    """Return lexical definition spans; conditional compilation is not evaluated."""
    starts = [0] + [match.end() for match in re.finditer('\n', text)]
    line_at = lambda offset: bisect_right(starts, offset)
    masked = NONCODE.sub(blank, text)
    masked = re.sub(r'^=\w.*?^=cut[^\n]*', blank, masked, flags=re.M | re.S)
    definitions = []

    # A continued macro can contain apparent function bodies. Remove directives
    # before scanning C, but retain macro spans as the more specific owner.
    directive = re.compile(r'^[ \t]*\#[^\n]*(?:\n|$)', re.M)
    lines = masked.splitlines(keepends=True)
    offset = 0
    in_directive = False
    macro = None
    pieces = []
    for line in lines:
        if not in_directive and directive.match(line):
            match = re.match(r'[ \t]*\#[ \t]*define[ \t]+([A-Za-z_]\w*)', line)
            macro = (match[1], line_at(offset)) if match else None
            in_directive = True
        if in_directive:
            pieces.append(re.sub(r'[^\n]', ' ', line))
            continued = line.rstrip('\r\n').endswith('\\')
            if not continued:
                if macro:
                    definitions.append(dict(name=macro[0], kind='macro', start=macro[1], end=line_at(offset)))
                macro = None
                in_directive = False
        else:
            pieces.append(line)
        offset += len(line)
    masked = ''.join(pieces)

    tokens = list(TOKEN.finditer(masked))
    parentheses, braces = {}, {}
    paren_stack, brace_stack = [], []
    candidates = []
    for index, token in enumerate(tokens):
        value = token.group()
        if value == '(':
            paren_stack.append(index)
        elif value == ')' and paren_stack:
            parentheses[index] = paren_stack.pop()
        elif value == '{':
            brace_stack.append(index)
            found = signature(tokens, index - 1, parentheses)
            if found:
                candidates.append((index, found))
        elif value == '}' and brace_stack:
            braces[brace_stack.pop()] = index

    for index, (name, start) in candidates:
        closing = braces.get(index)
        # An unmatched body is not enough evidence to label subsequent code.
        if closing is None:
            continue
        definitions.append(dict(name=name, kind='function', start=line_at(start),
                                end=line_at(tokens[closing].end())))

    if filename.endswith('.xs'):
        definitions.extend(xs_definitions(masked, line_at))
    return definitions


def xs_definitions(masked, line_at):
    """Find XSUB signatures followed by XS sections instead of a C body."""
    headers = list(re.finditer(r'^([A-Za-z_]\w*(?:::\w+)*)[ \t]*\(', masked, re.M))
    boundaries = list(re.finditer(r'^(?:MODULE|BOOT|INCLUDE|PROTOTYPES|TYPEMAP)\s*:', masked, re.M))
    definitions = []
    for index, header in enumerate(headers):
        end = headers[index + 1].start() if index + 1 < len(headers) else len(masked)
        end = min([end] + [boundary.start() for boundary in boundaries if boundary.start() > header.start()])
        body = masked[header.start():end]
        section = re.search(r'^(?:CODE|PPCODE|PREINIT|INIT|INPUT|OUTPUT|ALIAS|CLEANUP)\s*:', body, re.M)
        closing = body.find(')')
        if not section or closing < 0 or re.search(r'[;{]', body[closing + 1:section.start()]):
            continue
        definitions.append(dict(name=header[1], kind='XS function', start=line_at(header.start()),
                                end=line_at(max(header.start(), end - 1))))
    return definitions


def enclosing_definition(definitions, line):
    """Prefer a macro or the narrowest enclosing function; leave unknowns explicit."""
    matches = [entry for entry in definitions if entry['start'] <= line <= entry['end']]
    if not matches:
        return dict(name='', kind='undetermined')
    owner = min(matches, key=lambda entry: (entry['kind'] != 'macro', entry['end'] - entry['start']))
    return dict(name=owner['name'], kind=owner['kind'])
