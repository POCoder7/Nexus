import { Directive } from '@angular/core';

/** Table adapter: data-table styles (global `.ds-table` rules in styles.css) until the design-system table (OD-04). */
@Directive({ selector: 'table[dsTable]', host: { class: 'ds-table' } })
export class DsTableDirective {}
