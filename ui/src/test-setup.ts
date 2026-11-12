// Unit-test environment (jsdom) gaps that real browsers do not have. Behaviour under test is unchanged; the end-to-end
// suite runs the same components in real Chromium.
if (!Element.prototype.scrollTo) {
  Element.prototype.scrollTo = function scrollTo(this: Element, options?: ScrollToOptions | number, y?: number): void {
    const el = this as HTMLElement;
    if (typeof options === 'object') {
      el.scrollTop = options.top ?? el.scrollTop;
      el.scrollLeft = options.left ?? el.scrollLeft;
    } else if (typeof options === 'number') {
      el.scrollLeft = options;
      el.scrollTop = y ?? 0;
    }
  };
}
