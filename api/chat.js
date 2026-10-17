export default async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  const key = process.env.OPENAI_API_KEY;

  if (!key) {
    return res.status(503).json({
      error: 'ChatGPT is not connected yet. Add OPENAI_API_KEY in Vercel.'
    });
  }

  const { messages } = req.body || {};

  if (!Array.isArray(messages) || !messages.length) {
    return res.status(400).json({
      error: 'No messages supplied.'
    });
  }

  const safeMessages = messages
    .filter(
      m =>
        m &&
        (m.role === 'user' || m.role === 'assistant') &&
        typeof m.content === 'string'
    )
    .slice(-12)
    .map(m => ({
      role: m.role,
      content: m.content.slice(0, 4000)
    }));

  try {
    const response = await fetch('https://api.openai.com/v1/responses', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${key}`
      },
      body: JSON.stringify({
        model: 'gpt-6-luna',
        input: safeMessages,
        instructions:
          'You are the ChatGPT assistant inside BMN Community. Be helpful, concise, friendly, and conversational. Do not claim to be a human BMN creator.'
      })
    });

    const data = await response.json();

    if (!response.ok) {
      return res.status(response.status).json({
        error: data?.error?.message || 'OpenAI request failed.'
      });
    }

    return res.status(200).json({
      content: data.output_text || 'I could not generate a response.'
    });
  } catch (error) {
    return res.status(500).json({
      error: error?.message || 'ChatGPT request failed.'
    });
  }
}
