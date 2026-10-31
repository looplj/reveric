//! Native node identity, structural validation and ordered batch coalescing.
use super::schema;
use crate::api::ui::{UiBatch, UiOp, UiValue};
use crate::api::value::JsValue;
use rquickjs::{Ctx, Error, FromJs, IntoJs, Result, Value, qjs};
use std::collections::HashMap;

pub(crate) struct Node {
    pub component: String,
    pub parent: Option<(u64, String)>,
    pub slots: HashMap<String, Vec<u64>>,
    pub handlers: HashMap<String, u64>,
}
pub(crate) struct Listener {
    pub function: qjs::JSValue,
    pub owner: u32,
    pub node: u64,
    pub event: String,
}
pub(crate) struct Tree {
    pub nodes: HashMap<u64, Node>,
    pub listeners: HashMap<u64, Listener>,
    pub next_node: u64,
    pub next_handler: u64,
    pub pending: Vec<UiOp>,
    pub next_seq: u64,
    pub awaiting: Option<u64>,
    pub last_ack: u64,
    pub revisions: HashMap<u64, u64>,
}
impl Tree {
    pub fn new() -> Self {
        let mut nodes = HashMap::new();
        nodes.insert(
            1,
            Node {
                component: "Column".into(),
                parent: None,
                slots: HashMap::new(),
                handlers: HashMap::new(),
            },
        );
        Self {
            nodes,
            listeners: HashMap::new(),
            next_node: 2,
            next_handler: 1,
            pending: Vec::new(),
            next_seq: 1,
            awaiting: None,
            last_ack: 0,
            revisions: HashMap::new(),
        }
    }
    pub fn push(&mut self, op: UiOp) -> Result<()> {
        if let UiOp::Set {
            id,
            props,
            unset,
            edit_revision,
        } = &op
        {
            for previous in self.pending.iter_mut().rev() {
                match previous {
                    UiOp::Set {
                        id: other,
                        props: old,
                        unset: old_unset,
                        edit_revision: revision,
                    } if other == id => {
                        for key in unset {
                            old.remove(key);
                            if !old_unset.contains(key) {
                                old_unset.push(key.clone());
                            }
                        }
                        for (key, value) in props {
                            old_unset.retain(|v| v != key);
                            old.insert(key.clone(), value.clone());
                        }
                        *revision = *edit_revision;
                        return self.check_budget();
                    }
                    UiOp::Set { .. } => {}
                    _ => break,
                }
            }
        }
        self.pending.push(op);
        self.check_budget()
    }
    fn check_budget(&self) -> Result<()> {
        if self.pending.len() > 4096
            || self.pending.iter().map(op_size).sum::<usize>() > 1024 * 1024
        {
            return Err(invalid("plugin_ui_limit: pending batch exceeded"));
        }
        Ok(())
    }
    pub fn create(&mut self, component: String) -> Result<u64> {
        if schema::Component::parse(&component).is_none() {
            return Err(invalid("Unknown component"));
        }
        if self.nodes.len() >= 2000 {
            return Err(invalid("plugin_ui_limit: nodes exceeded"));
        }
        let id = self.next_node;
        self.next_node += 1;
        self.nodes.insert(
            id,
            Node {
                component: component.clone(),
                parent: None,
                slots: HashMap::new(),
                handlers: HashMap::new(),
            },
        );
        self.push(UiOp::Create { id, component })?;
        Ok(id)
    }
    pub fn insert(
        &mut self,
        parent: u64,
        child: u64,
        slot: String,
        before: Option<u64>,
    ) -> Result<()> {
        if child == 1 || !self.nodes.contains_key(&child) {
            return Err(invalid("Invalid child"));
        }
        let target = self
            .nodes
            .get(&parent)
            .ok_or_else(|| invalid("Unknown parent"))?;
        let one =
            super::schema::slot(&target.component, &slot).ok_or_else(|| invalid("Unknown slot"))?;
        let existing = target.slots.get(&slot);
        if one && existing.is_some_and(|children| children.iter().any(|id| *id != child)) {
            return Err(invalid("Slot accepts one child"));
        }
        if before.is_some_and(|id| {
            id != child && !existing.is_some_and(|children| children.contains(&id))
        }) {
            return Err(invalid("Invalid before node"));
        }
        if before == Some(child) {
            return Ok(());
        }
        let mut ancestor = Some(parent);
        let mut depth = self.depth(child);
        while let Some(id) = ancestor {
            if id == child {
                return Err(invalid("Node cycle"));
            }
            depth += 1;
            if depth > 32 {
                return Err(invalid("plugin_ui_limit: tree depth exceeded"));
            }
            ancestor = self
                .nodes
                .get(&id)
                .and_then(|node| node.parent.as_ref().map(|p| p.0));
        }
        self.detach(child);
        let node = self.nodes.get_mut(&parent).unwrap();
        let children = node.slots.entry(slot.clone()).or_default();
        let index = before
            .and_then(|id| children.iter().position(|v| *v == id))
            .unwrap_or(children.len());
        children.insert(index, child);
        self.nodes.get_mut(&child).unwrap().parent = Some((parent, slot.clone()));
        self.push(UiOp::Insert {
            parent,
            child,
            slot,
            before,
        })
    }
    /// Moves `order` into place, inserting only nodes outside the longest
    /// subsequence that already has the right relative order.
    pub fn reorder(&mut self, parent: u64, slot: &str, order: &[u64]) -> Result<()> {
        let current: HashMap<u64, usize> = self
            .nodes
            .get(&parent)
            .and_then(|node| node.slots.get(slot))
            .map(|children| {
                children
                    .iter()
                    .enumerate()
                    .map(|(i, id)| (*id, i))
                    .collect()
            })
            .unwrap_or_default();
        let positions: Vec<_> = order.iter().map(|id| current.get(id).copied()).collect();
        let stable = longest_increasing(&positions);
        let mut before = None;
        for (index, child) in order.iter().enumerate().rev() {
            if !stable[index] {
                self.insert(parent, *child, slot.into(), before)?;
            }
            before = Some(*child);
        }
        Ok(())
    }
    fn depth(&self, id: u64) -> usize {
        1 + self.nodes[&id]
            .slots
            .values()
            .flatten()
            .map(|id| self.depth(*id))
            .max()
            .unwrap_or(0)
    }
    fn detach(&mut self, id: u64) -> Option<(u64, String)> {
        let parent = self.nodes.get_mut(&id)?.parent.take();
        if let Some((parent, slot)) = &parent {
            if let Some(children) = self
                .nodes
                .get_mut(parent)
                .and_then(|node| node.slots.get_mut(slot))
            {
                children.retain(|child| *child != id);
            }
        }
        parent
    }
    pub fn dispose(&mut self, id: u64, freed: &mut Vec<qjs::JSValue>) -> Result<()> {
        if id == 1 {
            return Err(invalid("Cannot release root"));
        }
        let Some(node) = self.nodes.get(&id) else {
            return Ok(());
        };
        let children: Vec<_> = node.slots.values().flatten().copied().collect();
        for child in children {
            self.dispose(child, freed)?;
        }
        if let Some((parent, slot)) = self.detach(id) {
            self.push(UiOp::Remove {
                parent,
                child: id,
                slot,
            })?;
        }
        let node = self.nodes.remove(&id).unwrap();
        for handler in node.handlers.values() {
            if let Some(listener) = self.listeners.remove(handler) {
                freed.push(listener.function);
            }
        }
        self.revisions.remove(&id);
        self.push(UiOp::Release { id })
    }
    pub fn flush(&mut self, surface: &str, generation: u32) -> Option<UiBatch> {
        if self.awaiting.is_some() || (self.pending.is_empty() && self.next_seq != 1) {
            return None;
        }
        let seq = self.next_seq;
        self.next_seq += 1;
        self.awaiting = Some(seq);
        Some(UiBatch {
            surface: surface.into(),
            generation,
            seq,
            ops: std::mem::take(&mut self.pending),
        })
    }
    pub fn ack(&mut self, seq: u64) -> Result<()> {
        if seq == self.last_ack {
            return Ok(());
        }
        if self.awaiting != Some(seq) {
            return Err(invalid("Invalid batch acknowledgement"));
        }
        self.last_ack = seq;
        self.awaiting = None;
        Ok(())
    }
}
fn longest_increasing(positions: &[Option<usize>]) -> Vec<bool> {
    let mut tails: Vec<usize> = Vec::new();
    let mut previous = vec![None; positions.len()];
    for (index, position) in positions.iter().enumerate() {
        let Some(position) = *position else {
            continue;
        };
        let at = tails.partition_point(|tail| positions[*tail] < Some(position));
        previous[index] = at.checked_sub(1).map(|at| tails[at]);
        if at == tails.len() {
            tails.push(index);
        } else {
            tails[at] = index;
        }
    }
    let mut stable = vec![false; positions.len()];
    let mut cursor = tails.last().copied();
    while let Some(index) = cursor {
        stable[index] = true;
        cursor = previous[index];
    }
    stable
}
pub(crate) fn invalid(message: &str) -> Error {
    Error::new_from_js_message("UI", "protocol", message)
}
pub(crate) fn value_size(value: &UiValue) -> usize {
    match value {
        UiValue::Null => 4,
        UiValue::Boolean(v) => {
            if *v {
                4
            } else {
                5
            }
        }
        UiValue::Number(v) => v.to_string().len(),
        UiValue::String(v) => {
            2 + v
                .chars()
                .map(|c| match c {
                    '"' | '\\' => 2,
                    '\u{0000}'..='\u{001f}' => 6,
                    _ => c.len_utf8(),
                })
                .sum::<usize>()
        }
        UiValue::Array(v) => {
            2 + v.iter().map(value_size).sum::<usize>() + v.len().saturating_sub(1)
        }
        UiValue::Object(v) => {
            2 + v
                .iter()
                .map(|(k, v)| value_size(&UiValue::String(k.clone())) + 1 + value_size(v))
                .sum::<usize>()
                + v.len().saturating_sub(1)
        }
    }
}
fn op_size(op: &UiOp) -> usize {
    match op {
        UiOp::Set { props, unset, .. } => {
            128 + props
                .iter()
                .map(|(key, value)| key.len() + value_size(value) + 4)
                .sum::<usize>()
                + unset.iter().map(|k| k.len() + 3).sum::<usize>()
        }
        _ => format!("{op:?}").len() + 64,
    }
}
fn from_value(value: JsValue, depth: usize) -> Result<UiValue> {
    if depth > 32 {
        return Err(invalid("UI value nesting exceeded"));
    }
    Ok(match value {
        JsValue::None => UiValue::Null,
        JsValue::Boolean(v) => UiValue::Boolean(v),
        JsValue::Integer(v) => UiValue::Number(v as f64),
        JsValue::Float(v) if v.is_finite() => UiValue::Number(v),
        JsValue::String(v) => UiValue::String(v),
        JsValue::Array(v) => UiValue::Array(
            v.into_iter()
                .map(|v| from_value(v, depth + 1))
                .collect::<Result<_>>()?,
        ),
        JsValue::Object(v) => UiValue::Object(
            v.into_iter()
                .map(|(k, v)| Ok((k, from_value(v, depth + 1)?)))
                .collect::<Result<_>>()?,
        ),
        _ => return Err(invalid("Only finite JSON values are accepted")),
    })
}
pub(crate) fn decode<'js>(ctx: &Ctx<'js>, value: Value<'js>) -> Result<UiValue> {
    let value = from_value(JsValue::from_js(ctx, value)?, 0)?;
    if value_size(&value) > 1024 * 1024 {
        return Err(invalid("UI value exceeds 1 MB"));
    }
    Ok(value)
}
fn to_value(value: UiValue) -> JsValue {
    match value {
        UiValue::Null => JsValue::None,
        UiValue::Boolean(v) => JsValue::Boolean(v),
        UiValue::Number(v) => JsValue::Float(v),
        UiValue::String(v) => JsValue::String(v),
        UiValue::Array(v) => JsValue::Array(v.into_iter().map(to_value).collect()),
        UiValue::Object(v) => {
            JsValue::Object(v.into_iter().map(|(k, v)| (k, to_value(v))).collect())
        }
    }
}
pub(crate) fn encode<'js>(ctx: &Ctx<'js>, value: UiValue) -> Result<Value<'js>> {
    to_value(value).into_js(ctx)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reorder_moves_only_rows_outside_the_stable_order() {
        let mut tree = Tree::new();
        let parent = tree.create("Fragment".into()).unwrap();
        let rows: Vec<_> = (0..5)
            .map(|_| {
                let row = tree.create("Text".into()).unwrap();
                tree.insert(parent, row, "children".into(), None).unwrap();
                row
            })
            .collect();
        for (order, moves) in [
            (vec![rows[4], rows[0], rows[1], rows[2], rows[3]], 1),
            (vec![rows[3], rows[2], rows[1], rows[0], rows[4]], 4),
            (vec![rows[3], rows[2], rows[1], rows[0], rows[4]], 0),
        ] {
            tree.pending.clear();
            tree.reorder(parent, "children", &order).unwrap();
            let inserts = tree
                .pending
                .iter()
                .filter(|op| matches!(op, UiOp::Insert { .. }));
            assert_eq!(inserts.count(), moves);
            assert_eq!(tree.nodes[&parent].slots["children"], order);
        }
    }
}
