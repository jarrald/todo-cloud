import { useEffect, useState } from "react";
import "./App.css";
import TodoList from "./components/TodoList";
import Todo from "./models/todo";
import todoService from "./services/todoService";
import NewTodo from "./components/NewTodo";
import Statistics from "./components/Statistics";

function App() {
  const [todos, setTodos] = useState<Todo[]>([]);
  const [statisticsRefreshKey, setStatisticsRefreshKey] = useState(0);

  useEffect(() => {
    loadTodos();
  }, []);

  const loadTodos = async () => {
    const todos = await todoService.getAll();
    setTodos(todos);
  };

  const deleteTodo = async (id: string) => {
    await todoService.delete(id);
    setStatisticsRefreshKey((key) => key + 1);
    loadTodos();
  };

  const completeTodo = async (id: string) => {
    await todoService.complete(id);
    setStatisticsRefreshKey((key) => key + 1);
    loadTodos();
  };

  const addTodo = async (title: string) => {
    const newTodo = await todoService.create(title);
    setTodos([...todos, newTodo]);
    setStatisticsRefreshKey((key) => key + 1);
  };

  return (
    <div style={{ margin: "2rem" }}>
      <NewTodo onAddTodo={addTodo} />
      <Statistics refreshKey={statisticsRefreshKey} />
      <TodoList todos={todos} onDelete={deleteTodo} onComplete={completeTodo} />
    </div>
  );
}

export default App;
