import { app, HttpRequest, HttpResponseInit, InvocationContext } from "@azure/functions";
import { MongoClient } from "mongodb";

interface Statistics {
  total: number;
  completed: number;
  pending: number;
}

let connection: Promise<MongoClient> | undefined;

function getConnection(): Promise<MongoClient> {
  if (!connection) {
    const uri = process.env.MONGO_URI;
    if (!uri) {
      throw new Error("MONGO_URI is not configured");
    }

    const client = new MongoClient(uri);
    connection = client.connect().catch((error: unknown) => {
      connection = undefined;
      throw error;
    });
  }
  return connection;
}

export async function statistics(
  _request: HttpRequest,
  context: InvocationContext,
): Promise<HttpResponseInit> {
  try {
    const client = await getConnection();
    const result = await client.db().collection("todos").aggregate<{
      total: number;
      completed: number;
    }>([
      {
        $group: {
          _id: null,
          total: { $sum: 1 },
          completed: { $sum: { $cond: [{ $eq: ["$completed", true] }, 1, 0] } },
        },
      },
    ]).next();

    const total = result?.total ?? 0;
    const completed = result?.completed ?? 0;
    const body: Statistics = { total, completed, pending: total - completed };
    return { jsonBody: body };
  } catch (error) {
    context.error("Failed to load todo statistics", error);
    return { status: 500, jsonBody: { error: "Failed to load todo statistics" } };
  }
}

app.http("statistics", {
  methods: ["GET"],
  authLevel: "anonymous",
  handler: statistics,
});
