import axios from "axios";

export interface Statistics {
  total: number;
  completed: number;
  pending: number;
}

export async function getStatistics(): Promise<Statistics> {
  const baseURL = import.meta.env.VITE_STATISTICS_URL;
  if (!baseURL) {
    throw new Error("VITE_STATISTICS_URL is not configured");
  }
  const response = await axios.get<Statistics>("/api/statistics", { baseURL });
  return response.data;
}
