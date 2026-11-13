const { after, test } = require("node:test");
const assert = require("node:assert/strict");
const { MongoMemoryServer } = require("mongodb-memory-server");
const { MongoClient } = require("mongodb");
const { statistics } = require("../dist/statistics");

const errors = [];
const context = { error: (...args) => errors.push(args) };
const clients = [];
const connect = MongoClient.prototype.connect;
MongoClient.prototype.connect = function (...args) {
  clients.push(this);
  return connect.apply(this, args);
};
let server;

after(async () => {
  MongoClient.prototype.connect = connect;
  await Promise.all(clients.map((client) => client.close()));
  if (server) await server.stop();
});

test("returns an error when the database is not configured", async () => {
  delete process.env.MONGO_URI;
  const response = await statistics({}, context);
  assert.equal(response.status, 500);
  assert.deepEqual(response.jsonBody, { error: "Failed to load todo statistics" });
  assert.equal(errors.length, 1);
});

test("returns an error when the database is unreachable", async () => {
  process.env.MONGO_URI = "mongodb://127.0.0.1:1/todos?serverSelectionTimeoutMS=100";
  const response = await statistics({}, context);
  assert.equal(response.status, 500);
  assert.deepEqual(response.jsonBody, { error: "Failed to load todo statistics" });
});

test("counts the current todos, including an empty collection", async () => {
  server = await MongoMemoryServer.create();
  process.env.MONGO_URI = server.getUri("todos");
  const client = await MongoClient.connect(process.env.MONGO_URI);
  const todos = client.db().collection("todos");

  assert.deepEqual((await statistics({}, context)).jsonBody, {
    total: 0,
    completed: 0,
    pending: 0,
  });

  await todos.insertMany([
    { completed: true },
    { completed: true },
    { completed: false },
    {},
  ]);
  assert.deepEqual((await statistics({}, context)).jsonBody, {
    total: 4,
    completed: 2,
    pending: 2,
  });

  await todos.deleteOne({ completed: true });
  assert.deepEqual((await statistics({}, context)).jsonBody, {
    total: 3,
    completed: 1,
    pending: 2,
  });
});
