library css_shim;

import 'package:angular/core/parser/characters.dart';

String shimCssText(String css, String tag) =>
    new _CssShim(tag).shimCssText(css);


/**
 * This is a shim for ShadowDOM css styling. It adds an attribute selector suffix
 * to each simple selector.
 *
 * So:
 *
 *    one, two {color: red;}
 *
 * Becomes:
 *
 *    one[tag], two[tag] {color: red;}
 *
 * It can handle the following selectors:
 * * `one::before`
 * * `one two`
 * * `one>two`
 * * `one+two`
 * * `one~two`
 * * `.one.two`
 * * `one[attr="value"]`
 * * `one[attr^="value"]`
 * * `one[attr$="value"]`
 * * `one[attr*="value"]`
 * * `one[attr|="value"]`
 * * `one[attr]`
 * * `[is=one]`
 *
 * It can handle :host:
 * * `:host`
 * * `:host(.x)`
 *
 * When the shim is not powerful enough, you can fall back on the polyfill-next-selector,
 * polyfill-unscoped-next-selector, and polyfill-non-strict directives.
 *
 * * `polyfill-next-selector {content: 'x > y'}` z {} becomes `x[tag] > y[tag] {}`
 * * `polyfill-unscoped-next-selector {content: 'x > y'} z {}` becomes `x > y {}`
 * * `polyfill-non-strict {} z {}` becomes `tag z {}`
 *
 * See http://www.polymer-project.org/docs/polymer/styling.html#at-polyfill
 *
 * This implementation is a simplified version of the shim provided by platform.js:
 * https://github.com/Polymer/platform-dev/blob/master/src/ShadowCSS.js
 */
class _CssShim {
  static final List SELECTOR_SPLITS = const [' ', '>', '+', '~'];

  static final RegExp CONTENT = new RegExp(
      r"[^}]*"
      r"content:\s*"
      "('|\")([^\\1]*)\\1"
      r"[^}]*}",
      caseSensitive: false,
      multiLine: true
  );

  static final String HOST_TOKEN = '-host-element';
  static final RegExp COLON_SELECTORS = new RegExp(r'(' + HOST_TOKEN + r')(\(.*\))?(.*)',
      caseSensitive: false);
  static final RegExp SIMPLE_SELECTORS = new RegExp(r'([^:]*)(:*)(.*)', caseSensitive: false);
  static final RegExp IS_SELECTORS = new RegExp(r'\[is="([^\]]*)"\]', caseSensitive: false);

  // See https://github.com/Polymer/platform-dev/blob/master/src/ShadowCSS.js#L561
  static final String PAREN_SUFFIX = r')(?:\(('
      r'(?:\([^)(]*\)|[^)(]*)+?'
      r')\))?([^,{]*)';
  static final RegExp COLON_HOST = new RegExp('($HOST_TOKEN$PAREN_SUFFIX',
      caseSensitive: false, multiLine: true);

  static final String POLYFILL_NON_STRICT = "polyfill-non-strict";
  static final String POLYFILL_UNSCOPED_NEXT_SELECTOR = "polyfill-unscoped-next-selector";
  static final String POLYFILL_NEXT_SELECTOR = "polyfill-next-selector";

  static final List<RegExp> COMBINATORS = [
    new RegExp(r'/shadow/', caseSensitive: false),
    new RegExp(r'/shadow-deep/', caseSensitive: false),
    new RegExp(r'::shadow', caseSensitive: false),
    new RegExp(r'/deep/', caseSensitive: false)
  ];

  final String tag;
  final String attr;

  _CssShim(String tag)
      : tag = tag, attr = "[$tag]";

  String shimCssText(String css) {
    final preprocessed = convertColonHost(css);
    final rules = cssToRules(preprocessed);
    return scopeRules(rules);
  }

  String convertColonHost(String css) {
    css = css.replaceAll(":host", HOST_TOKEN);

    String partReplacer(host, part, suffix) =>
        "$host${part.replaceAll(HOST_TOKEN, '')}$suffix";

    return css.replaceAllMapped(COLON_HOST, (m) {
      final base = HOST_TOKEN;
      final inParens = m.group(2);
      final rest = m.group(3);

      if (inParens != null && inParens.isNotEmpty) {
        return inParens.split(',')
            .map((p) => p.trim())
            .where((_) => _.isNotEmpty)
            .map((p) => partReplacer(base, p, rest))
            .join(",");
      } else {
        return "$base$rest";
      }
    });
  }

  List<_Rule> cssToRules(String css) =>
      new _Parser(css).parse();

  String scopeRules(List<_Rule> rules, {bool emitMode: false}) {
    if (emitMode) {
      return rules.map(ruleToString).join("\n");
    }

    final scopedRules = [];
    var prevRule;
    rules.forEach((rule) {
      if (prevRule != null && prevRule.selectorText == POLYFILL_NON_STRICT) {
        scopedRules.add(scopeNonStrictMode(rule, emitMode));
      } else if (prevRule != null && prevRule.selectorText == POLYFILL_UNSCOPED_NEXT_SELECTOR) {
        final content = extractContent(prevRule);
        scopedRules.add(ruleToString(new _Rule(content, body: rule.body)));

      } else if (prevRule != null && prevRule.selectorText == POLYFILL_NEXT_SELECTOR) {
        final content = extractContent(prevRule);
        scopedRules.add(scopeStrictMode(new _Rule(content, body: rule.body), false));

      } else if (rule.selectorText != POLYFILL_NON_STRICT &&
          rule.selectorText != POLYFILL_UNSCOPED_NEXT_SELECTOR &&
          rule.selectorText != POLYFILL_NEXT_SELECTOR) {
        scopedRules.add(scopeStrictMode(rule, false));
      }

      prevRule = rule;
    });

    return scopedRules.join("\n");
  }

  String extractContent(_Rule rule) {
    return CONTENT.firstMatch(rule.body)[2];
  }

  String ruleToString(_Rule rule) {
    return "${rule.selectorText} ${rule.body}";
  }

  String scopeStrictMode(_Rule rule, bool emitMode) {
    if (rule.hasNestedRules) {
      final rules = scopeRules(rule.rules, emitMode: rule.selectorText.contains("keyframes"));
      return "${rule.selectorText} {\n$rules\n}";
    } else {
      final scopedSelector = scopeSelector(rule.selectorText, strict: true);
      final scopedBody = cssText(rule);
      return "$scopedSelector $scopedBody";
    }
  }

  String scopeNonStrictMode(_Rule rule, bool emitMode) {
    if (rule.hasNestedRules && rule.selectorText == "keyframes") {
      final rules = scopeRules(rule.rules, emitMode: true);
      return '${rule.selectorText} {\n$rules\n}';
    }
    final scopedBody = cssText(rule);
    final scopedSelector = scopeSelector(rule.selectorText, strict: false);
    return "${scopedSelector} $scopedBody";
  }

  String scopeSelector(String selector, {bool strict}) {
    final parts = replaceCombinators(selector).split(",");
    final scopedParts = parts.fold([], (res, p) {
      res.add(scopeSimpleSelector(p.trim(), strict: strict));
      return res;
    });
    return scopedParts.join(", ");
  }

  String replaceCombinators(String selector) {
    return COMBINATORS.fold(selector, (sel, combinator) {
      return sel.replaceAll(combinator, ' ');
    });
  }

  String scopeSimpleSelector(String selector, {bool strict}) {
    if (selector.contains(HOST_TOKEN)) {
      return replaceColonSelectors(selector);
    } else if (strict) {
      return insertTagToEverySelectorPart(selector);
    } else {
      return "$tag $selector";
    }
  }

  String cssText(_Rule rule) => rule.body;

  String replaceColonSelectors(String css) {
    return css.replaceAllMapped(COLON_SELECTORS, (m) {
      final selectorInParens = m[2] == null ? "" : m[2].substring(1, m[2].length - 1);
      final rest = m[3];
      return "$tag$selectorInParens$rest";
    });
  }

  String insertTagToEverySelectorPart(String selector) {
    selector = handleIsSelector(selector);

    SELECTOR_SPLITS.forEach((split) {
      final parts = selector.split(split).map((p) => p.trim());
      selector = parts.map(insertAttrSuffixIntoSelectorPart).join(split);
    });

    return selector;
  }

  String insertAttrSuffixIntoSelectorPart(String p) {
    final shouldInsert = p.isNotEmpty && !SELECTOR_SPLITS.contains(p) && !p.contains(attr);
    return shouldInsert ? insertAttr(p) : p;
  }

  String insertAttr(String selector) {
    return selector.replaceAllMapped(SIMPLE_SELECTORS, (m) {
      final basePart = m[1];
      final colonPart = m[2];
      final rest = m[3];
      return m[0].isNotEmpty ? "$basePart$attr$colonPart$rest" : "";
    });
  }

  String handleIsSelector(String selector) =>
      selector.replaceAllMapped(IS_SELECTORS, (m) => m[1]);
}



class _Token {
  static final _Token EOF = new _Token(null);
  final String string;
  final String type;
  _Token(this.string, [this.type]);

  String toString() => "TOKEN[$string, $type]";
}

class _Lexer {
  int peek = 0;
  int index = -1;
  final String input;
  final int length;

  _Lexer(String input)
      : input = input, length = input.length {
    advance();
  }

  List<_Token> parse() {
    final res = [];
    var t = scanToken();
    while (t != _Token.EOF) {
      res.add(t);
      t = scanToken();
    }
    return res;
  }

  _Token scanToken() {
    skipWhitespace();

    if (peek == $EOF) return _Token.EOF;
    if (isBodyEnd(peek)) {
      advance();
      return new _Token("}", "rparen");
    }
    if (isDeclaration(peek)) return scanDeclaration();
    if (isSelector(peek)) return scanSelector();
    if (isBodyStart(peek)) return scanBody();

    return _Token.EOF;
  }

  bool isSelector(int v) => !isBodyStart(v) && v != $EOF;
  bool isBodyStart(int v) => v == $LBRACE;
  bool isBodyEnd(int v) => v == $RBRACE;
  bool isDeclaration(int v) => v == 64; //@ = 64

  void skipWhitespace() {
    while (isWhitespace(peek)) {
      if (++index >= length) {
        peek = $EOF;
        return null;
      } else {
        peek = input.codeUnitAt(index);
      }
    }
  }

  _Token scanSelector() {
    int start = index;
    advance();
    while (isSelector(peek)) advance();
    String string = input.substring(start, index).trim();
    return new _Token(string, "selector");
  }

  _Token scanBody() {
    int start = index;
    advance();
    while (!isBodyEnd(peek)) advance();
    advance();
    String string = input.substring(start, index);
    return new _Token(string, "body");
  }

  _Token scanDeclaration() {
    int start = index;
    advance();

    while (!isBodyStart(peek)) advance();
    String string = input.substring(start, index);

    advance(); //skip {

    // we assume that declaration cannot start with media and contain keyframes.
    String type = string.contains("keyframes") ? "keyframes" :
      (string.startsWith("@media") ? "media" : string);
    return new _Token(string, type);
  }

  void advance() {
    peek = ++index >= length ? $EOF : input.codeUnitAt(index);
  }
}

class _Rule {
  final String selectorText;
  final String body;
  final List<_Rule> rules;

  _Rule(this.selectorText, {this.body, this.rules});

  bool get hasNestedRules => rules != null;

  String toString() => "Rule[$selectorText $body]";
}

class _Parser {
  List<_Token> tokens;
  int currentIndex;

  _Parser(String input) {
    tokens = new _Lexer(input).parse();
    currentIndex = -1;
  }

  List<_Rule> parse() {
    final res = [];
    var rule;
    while ((rule = parseRule()) != null) {
      res.add(rule);
    }
    return res;
  }

  _Rule parseRule() {
    try {
      if (next.type == "media" || next.type == "keyframes") {
        return parseMedia(next.type);
      } else {
        return parseCssRule();
      }
    } catch (e) {
      return null;
    }
  }

  _Rule parseMedia(type) {
    advance(type);
    final media = current.string;

    final rules = [];
    while (next.type != "rparen") {
      rules.add(parseCssRule());
    }
    advance("rparen");

    return new _Rule(media.trim(), rules: rules);
  }

  _Rule parseCssRule() {
    advance("selector");
    final selector = current.string;

    advance("body");
    final body = current.string;

    return new _Rule(selector, body: body);
  }

  void advance(String expectedType) {
    currentIndex += 1;
    if (current.type != expectedType) {
      throw "Unexpected token ${current.type}. Expected $expectedType";
    }
  }

  _Token get current => tokens[currentIndex];
  _Token get next => tokens[currentIndex + 1];
}
