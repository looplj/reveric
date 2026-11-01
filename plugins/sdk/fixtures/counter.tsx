import {
  Button,
  Column,
  Each,
  If,
  List,
  Scroll,
  Text,
  TextField,
  computed,
  resource,
  signal,
  type PageContext,
} from "reveric-plugin-sdk/ui";
export default function Page(context: PageContext) {
  const count = signal(0),
    name = signal("");
  const label = computed(() => `Count ${count()}`);
  const loaded = resource(
    () => count(),
    async (value) => {
      await context.storage.get("preview.delay");
      return value;
    },
  );
  const rows = Array.from({ length: 1000 }, (_, index) => ({
    id: String(index),
    label: `Row ${index}`,
  }));
  return (
    <Scroll>
      <Column gap="sm">
        <Text text={label()} />
        <Button
          label="Add"
          onPress={() => count.update((value) => value + 1)}
        />
        <If when={count() > 0}>
          <Text text="Positive" />
        </If>
        <TextField
          label="Name"
          value={name()}
          onChange={(event) => {
            name.set(event.value);
            void context.view.setDirty(true);
          }}
        />
        <Text
          text={loaded.loading() ? "Loading" : `Loaded ${loaded.value() ?? 0}`}
        />
        <Each
          items={[{ id: "a", label: "Stable row" }]}
          key={(item) => item.id}
        >
          {(item) => <Text text={item().label} />}
        </Each>
        <List
          items={rows}
          key={(item) => item.id}
          itemExtent={32}
          height={160}
          renderItem={(item) => <Text variant="caption" text={item().label} />}
        />
      </Column>
    </Scroll>
  );
}
