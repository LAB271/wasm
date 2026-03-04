CREATE TABLE IF NOT EXISTS items (
    id    INTEGER PRIMARY KEY,
    name  TEXT NOT NULL,
    value INTEGER NOT NULL
);

INSERT INTO items (id, name, value) VALUES
    (1, 'Item 1', 42),
    (2, 'Item 2', 84),
    (3, 'Item 3', 126),
    (4, 'Item 4', 168),
    (5, 'Item 5', 210)
ON CONFLICT (id) DO NOTHING;
