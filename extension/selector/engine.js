/**
 * Selector Engine — computes CSS/XPath selectors and detects list patterns.
 * Pure functions, no DOM side effects.
 */

const SelectorEngine = (() => {

  /**
   * Generate a unique CSS selector for a single element.
   */
  function cssSelector(el) {
    if (el.id) return `#${CSS.escape(el.id)}`;
    const parts = [];
    let current = el;
    while (current && current !== document.body && current !== document.documentElement) {
      let selector = current.tagName.toLowerCase();
      if (current.id) {
        parts.unshift(`#${CSS.escape(current.id)}`);
        break;
      }
      // Use nth-child for precision
      const parent = current.parentElement;
      if (parent) {
        const index = Array.from(parent.children).indexOf(current) + 1;
        selector += `:nth-child(${index})`;
      }
      parts.unshift(selector);
      current = current.parentElement;
    }
    return parts.join(' > ');
  }

  /**
   * Generate an XPath for a single element.
   */
  function xpathSelector(el) {
    if (el.id) return `//*[@id="${el.id}"]`;
    const parts = [];
    let current = el;
    while (current && current !== document.body) {
      let tag = current.tagName.toLowerCase();
      const parent = current.parentElement;
      if (current.id) {
        parts.unshift(`//*[@id="${current.id}"]`);
        break;
      }
      if (parent) {
        const siblings = Array.from(parent.children).filter(s => s.tagName === current.tagName);
        if (siblings.length > 1) {
          const index = siblings.indexOf(current) + 1;
          tag += `[${index}]`;
        }
      }
      parts.unshift(tag);
      current = parent;
    }
    if (parts[0] && !parts[0].startsWith('//')) {
      parts.unshift('');
    }
    return '/' + parts.join('/');
  }

  /**
   * Find the Lowest Common Ancestor of two elements.
   */
  function findLCA(a, b) {
    const ancestors = new Set();
    let node = a;
    while (node) { ancestors.add(node); node = node.parentElement; }
    node = b;
    while (node) { if (ancestors.has(node)) return node; node = node.parentElement; }
    return document.body;
  }

  /**
   * Find LCA of multiple elements.
   */
  function findLCAMultiple(elements) {
    if (elements.length === 0) return document.body;
    if (elements.length === 1) return elements[0].parentElement || document.body;
    let lca = findLCA(elements[0], elements[1]);
    for (let i = 2; i < elements.length; i++) lca = findLCA(lca, elements[i]);
    return lca;
  }

  /**
   * Get the path from ancestor to element as an array of { tag, classes, el }.
   */
  function getPath(ancestor, el) {
    const path = [];
    let current = el;
    while (current && current !== ancestor) {
      path.unshift({
        tag: current.tagName.toLowerCase(),
        classes: getUsefulClasses(current),
        el: current,
      });
      current = current.parentElement;
    }
    return path;
  }

  /**
   * Filter out generated/utility class names, keep meaningful ones.
   */
  function getUsefulClasses(el) {
    return Array.from(el.classList)
      .filter(c => c.length < 40 && !c.match(/^(js-|_|svelte-|css-|sc-|styled-|w-|h-|p-|m-|text-|bg-|flex-|grid-|col-|row-)/))
      .slice(0, 3);
  }

  /**
   * Build a CSS selector piece for tag + classes.
   */
  function buildPiece(tag, classes) {
    if (classes.length > 0) {
      return tag + '.' + classes.map(c => CSS.escape(c)).join('.');
    }
    return tag;
  }

  /**
   * Given multiple selected elements that should be "the same kind of thing",
   * compute a generalized CSS selector that matches all of them.
   *
   * Strategy: find paths from LCA to each element, then at each depth level
   * intersect tag + classes to build a generalized path.
   */
  function computeListSelector(selectedElements) {
    if (selectedElements.length < 2) return null;

    const lca = findLCAMultiple(selectedElements);
    const paths = selectedElements.map(el => getPath(lca, el));

    // All paths must have the same depth
    const depth = paths[0].length;
    if (depth === 0) return null;
    const sameDepth = paths.every(p => p.length === depth);
    if (!sameDepth) return null;

    // At each depth level, intersect tag and classes
    const selectorParts = [];
    for (let d = 0; d < depth; d++) {
      const tags = paths.map(p => p[d].tag);
      // All must be same tag
      if (!tags.every(t => t === tags[0])) return null;
      const tag = tags[0];

      // Intersect classes at this level
      let sharedClasses = [...paths[0][d].classes];
      for (let i = 1; i < paths.length; i++) {
        const cls = new Set(paths[i][d].classes);
        sharedClasses = sharedClasses.filter(c => cls.has(c));
      }

      selectorParts.push(buildPiece(tag, sharedClasses));
    }

    // Build container CSS selector
    const containerCSS = cssSelector(lca);

    // The full generalized selector
    const itemPath = selectorParts.join(' > ');
    const fullSelector = `${containerCSS} > ${itemPath}`;

    // Verify: try querying, also try a relaxed version without nth-child in container
    let matched = document.querySelectorAll(fullSelector);

    // If no matches with the strict container selector, try relaxed (remove nth-child from container)
    if (matched.length < selectedElements.length) {
      const relaxedContainer = containerCSS.replace(/:nth-child\(\d+\)/g, '');
      const relaxedFull = `${relaxedContainer} > ${itemPath}`;
      const relaxedMatched = document.querySelectorAll(relaxedFull);
      if (relaxedMatched.length >= selectedElements.length) {
        return {
          container: relaxedContainer,
          containerEl: lca,
          item: itemPath,
          full: relaxedFull,
          matchCount: relaxedMatched.length,
          itemElements: Array.from(relaxedMatched),
        };
      }
    }

    // Also try without > (descendant instead of child) for more flexibility
    if (matched.length < selectedElements.length) {
      const descendantSelector = `${containerCSS} ${selectorParts[selectorParts.length - 1]}`;
      matched = document.querySelectorAll(descendantSelector);
      if (matched.length >= selectedElements.length) {
        return {
          container: containerCSS,
          containerEl: lca,
          item: selectorParts[selectorParts.length - 1],
          full: descendantSelector,
          matchCount: matched.length,
          itemElements: Array.from(matched),
        };
      }
    }

    return {
      container: containerCSS,
      containerEl: lca,
      item: itemPath,
      full: fullSelector,
      matchCount: matched.length,
      itemElements: Array.from(matched),
    };
  }

  /**
   * Given a list item element and a child element within it,
   * compute a relative CSS selector from item to child.
   */
  function relativeSelector(itemEl, childEl) {
    const parts = [];
    let current = childEl;
    while (current && current !== itemEl) {
      let sel = current.tagName.toLowerCase();
      const classes = getUsefulClasses(current);
      if (classes.length > 0) {
        sel += '.' + classes.map(c => CSS.escape(c)).join('.');
      }
      parts.unshift(sel);
      current = current.parentElement;
    }
    return parts.join(' > ') || childEl.tagName.toLowerCase();
  }

  /**
   * Detect if an element is likely an attribute (link, image, etc.)
   * and extract the attribute value type.
   */
  function detectFieldType(el) {
    const tag = el.tagName.toLowerCase();
    if (tag === 'a') return { type: 'link', attr: 'href', value: el.href };
    if (tag === 'img') return { type: 'image', attr: 'src', value: el.src };
    if (tag === 'time') return { type: 'time', attr: 'datetime', value: el.getAttribute('datetime') || el.textContent.trim() };
    if (tag === 'input') return { type: 'input', attr: 'value', value: el.value };
    return { type: 'text', attr: null, value: el.textContent.trim() };
  }

  /**
   * Identify major page sections for block highlighting.
   */
  function identifyPageBlocks() {
    const selectors = [
      'header', 'nav', 'main', 'article', 'section', 'aside', 'footer',
      '[role="banner"]', '[role="navigation"]', '[role="main"]', '[role="contentinfo"]',
      '.header', '.nav', '.sidebar', '.content', '.main', '.footer',
      '#header', '#nav', '#sidebar', '#content', '#main', '#footer',
    ];
    const blocks = [];
    const seen = new Set();
    for (const sel of selectors) {
      document.querySelectorAll(sel).forEach(el => {
        if (!seen.has(el) && el.offsetHeight > 50) {
          seen.add(el);
          blocks.push({ el, tag: el.tagName.toLowerCase(), role: el.getAttribute('role') || '', selector: cssSelector(el) });
        }
      });
    }
    return blocks;
  }

  return {
    cssSelector,
    xpathSelector,
    findLCA,
    findLCAMultiple,
    computeListSelector,
    relativeSelector,
    detectFieldType,
    identifyPageBlocks,
  };
})();

if (typeof window !== 'undefined') {
  window.__autocliSelectorEngine = SelectorEngine;
}
