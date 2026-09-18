const result = await fetch("http://localhost:3002/api/auth/register", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    email: "testuser_ecopin123@example.com",
    password: "Password1!",
    confirmPassword: "Password1!"
  })
});
const text = await result.text();
console.log(result.status, text);
