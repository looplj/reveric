import {
  Button,
  Column,
  Each,
  List,
  Scroll,
  Text,
  Wrap,
  batch,
  signal,
  resource,
  type PageContext,
} from "reveric-plugin-sdk/ui";
export default function Page(context: PageContext) {
  const count = signal(0),
    values = Array.from({ length: 40 }, (_, index) => ({
      id: String(index),
      value: signal(0),
    }));
  const query = signal(0),
    result = resource(
      () => query(),
      async (value) => {
        await context.storage.get(`search.${value}`);
        return value;
      },
    );
  const rows = signal(
    Array.from({ length: 1000 }, (_, index) => ({
      id: String(index),
      label: `Row ${index}`,
    })),
  );
  return (
    <Scroll>
      <Column gap="xs">
        <Text text={`Counter ${count()}`} testId="counter" />
        <Text text={`Search ${result.value() ?? -1}`} />
        <Button
          label="Search next"
          onPress={() => query.update((n) => n + 1)}
        />
        <Wrap gap="sm">
          <Button
            label="Increment"
            onPress={() => count.update((n) => n + 1)}
          />
          <Button
            label="Update forty"
            onPress={() =>
              batch(() => {
                count.update((n) => n + 1);
                for (const value of values) value.value.update((n) => n + 1);
              })
            }
          />
          <Button
            label="Reverse"
            onPress={() => rows.update((previous) => [...previous].reverse())}
          />
        </Wrap>
        <Each items={values} key={(item) => item.id}>
          {(value) => <Text text={`Dynamic ${value().value()}`} />}
        </Each>
        <List
          items={rows()}
          key={(row) => row.id}
          itemExtent={28}
          height={180}
          renderItem={(row) => <Text text={row().label} />}
        />
        <Each
          items={Array.from({ length: 200 }, (_, index) => ({
            id: String(index),
          }))}
          key={(row) => row.id}
        >
          {(row) => (
            <Button
              label={`Control ${row().id}`}
              onPress={() => count.update((n) => n + 1)}
            />
          )}
        </Each>
      </Column>
    </Scroll>
  );
}
