
DId a limited test run with bge-m3 model and nomic-embed-text models.
• bge-m3 scored my English and Spanish lake sentences at 0.91 
• nomic scored them at 0.52. 
• Unrelated sentences score about 0.3 in both models, so scores only matter relative to each other. Both models already return normalized vectors
• Vision’s first run took 26 seconds because of loading; later runs took 0.25 seconds. 
• Confidence was 1.0 even on wrong words like ‘Februarv’, so confidence is not a usable filter. 
• OCR captures interface clutter along with the content, which is why the description step matters.


