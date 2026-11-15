import type { Meta, StoryObj } from '@storybook/angular-vite';
import { QueryBuilderComponent, numberConditions } from './query-builder.component';
import { Group, emptyGroup, fieldsFrom } from './query-model';

/** The query builder (QRY-01, Phase 5 LLD §17.12). Synthetic property codes. */
const fields = fieldsFrom([
  { code: 'SYN.Ccy', label: 'Currency', category: 'Finance', dataType: 'string', listValues: ['EUR', 'USD'] },
  { code: 'SYN.Amt', label: 'Amount', category: 'Finance', dataType: 'integer' },
  { code: 'SYN.Open', label: 'Opened', category: 'Legal', dataType: 'date' },
]);
const nested: Group = {
  ...emptyGroup('all'),
  items: [
    { kind: 'condition', id: 101, field: 'attr:isLeaf', op: '=', value: 'true', value2: '', ci: false },
    { ...emptyGroup('any'), items: [
      { kind: 'condition', id: 102, field: 'prop:SYN.Ccy', op: 'in', value: 'EUR, USD', value2: '', ci: false },
      { kind: 'condition', id: 103, field: 'attr:name', op: 'starts_with', value: 'Syn', value2: '', ci: true },
      { kind: 'condition', id: 104, field: 'prop:SYN.Amt', op: 'between', value: '5', value2: '10', ci: false },
    ] },
  ],
};

const meta: Meta<QueryBuilderComponent> = {
  title: 'Custom/Query builder',
  component: QueryBuilderComponent,
  args: { fields, group: nested, numbers: numberConditions(nested) },
};
export default meta;
type Story = StoryObj<QueryBuilderComponent>;

export const Nested: Story = {};
export const Empty: Story = { args: { group: emptyGroup('all'), numbers: new Map() } };
