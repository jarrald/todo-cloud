import { useEffect, useState } from "react";
import { getStatistics, Statistics as StatisticsData } from "../services/statisticsService";

interface Props {
  refreshKey: number;
}

const Statistics = ({ refreshKey }: Props) => {
  const [statistics, setStatistics] = useState<StatisticsData | null>(null);
  const [error, setError] = useState(false);

  useEffect(() => {
    let active = true;
    setStatistics(null);
    setError(false);
    getStatistics()
      .then((data) => {
        if (active) setStatistics(data);
      })
      .catch(() => {
        if (active) setError(true);
      });
    return () => {
      active = false;
    };
  }, [refreshKey]);

  return (
    <section aria-label="Todo statistics" className="my-3">
      <h2>Statistics</h2>
      {error ? (
        <p role="alert">Could not load statistics.</p>
      ) : statistics ? (
        <p>
          Total: {statistics.total} | Completed: {statistics.completed} | Pending: {statistics.pending}
        </p>
      ) : (
        <p>Loading statistics...</p>
      )}
    </section>
  );
};

export default Statistics;
