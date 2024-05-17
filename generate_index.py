import os
import math

# Directory containing the script files
scripts_dir = './scripts'

# URL base for the scripts
curl_linux = 'curl -sSL'
curl_win = 'Invoke-RestMethod'
base_url = 'https://edoardotosin.com/tools/'

# Function to generate the list items
def generate_list_items(files):
    num_columns = 3  # Number of columns
    num_files = len(files)
    num_per_column = math.ceil(num_files / num_columns)

    columns = []
    for i in range(num_columns):
        start_index = i * num_per_column
        end_index = min((i + 1) * num_per_column, num_files)
        column_files = files[start_index:end_index]

        column_items = '\n'.join(
            f'''
            <li>
                <button onclick="copyCommand('{file}')" title="Click to copy command: {curl_linux} '{base_url}{file}' | bash">Copy</button>
                <a href="{file}">{file}</a>
            </li>
            ''' if file.endswith(('.sh', '.bash')) else
            f'''
            <li>
                <button onclick="copyCommand('{file}')" title="Click to copy command: {curl_linux} '{base_url}{file}' | python3">Copy</button>
                <a href="{file}">{file}</a>
            </li>
            ''' if file.endswith(('.py', '.pyw')) else
            f'''
            <li>
                <button onclick="copyCommand('{file}')" title="Click to copy command: {curl_win} '{base_url}{file}' | Invoke-Expression">Copy</button>
                <a href="{file}">{file}</a>
            </li>
            ''' if file.endswith('.ps1') else
            f'''
            <li>
                <button onclick="alert('Unsupported file type!')" title="Unsupported file type">Copy</button>
                <a href="{file}">{file}</a>
            </li>
            ''' for file in column_files
        )

        columns.append(f'<ul>{column_items}</ul>')

    return '\n'.join(f'<div style="float:left; width:33%;">{column}</div>' for column in columns)

# Read the directory and generate the HTML
try:
    files = [file for file in os.listdir(scripts_dir) if file.endswith(('.sh', '.bash', '.py', '.pyw', '.ps1'))]  # Exclude non-script files
    list_items = generate_list_items(files)
    html_content = f'''<!DOCTYPE html>
<html lang="en">
<head>
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta content="Automation Tools" property="og:site_name">
    <meta content="Computer Science Odyssey: Unraveling the Tech Maze" property="og:tagline" name="tagline">
    <meta content="Welcome to my personal tech hub! This website is a reflection of my journey in the fascinating world of technology. The blog section is a curated collection of posts demonstrating my ability to cre..." property="og:description" name="description">
    <meta content="Edoardo Tosin" property="article:author">
    <meta property="og:image" content="https://edoardotosin.com/assets/img/OGImg.jpg">
    <meta content="Automation Tools" property="og:title">
    <meta content="article" property="og:type">
    <meta content="https://edoardotosin.com/tools" property="og:url">
    <link rel="canonical" href="https://edoardotosin.com/tools">
    <title>Automation Tools - Edoardo Tosin</title>
    <!-- Style -->
    <link href="../assets/css/style.css" rel="stylesheet" media="all" class="default" />
    <link href="../assets/css/main.css" rel="stylesheet" media="all" class="default" />
    <link href="../assets/css/Util.css" rel="stylesheet" media="all" class="default" />
    <style>
        body {{
            font-family: Arial, sans-serif;
        }}
        h1 {{
            text-align: center;
        }}
        ul {{
            list-style-type: none;
            padding: 0;
        }}
        li {{
            margin: 5px 0;
            display: flex;
            align-items: center;
        }}
        a {{
            margin-left: 10px;
            text-decoration: none;
            color: #007BFF;
        }}
        a:hover {{
            text-decoration: underline;
        }}
        button {{
            margin-left: 10px;
            padding: 5px 10px;
            cursor: pointer;
            background-color: #007BFF;
            color: #FFF;
            border: none;
            border-radius: 3px;
        }}
        button:hover {{
            background-color: #0056b3;
        }}
        .copy-notification {{
            position: fixed;
            top: 20em; /* Adjusted position to avoid overlapping with the title */
            left: 50%;
            transform: translateX(-50%);
            display: none;
            padding: 10px;
            background-color: #dff0d8;
            color: #3c763d;
            border: 1px solid #d6e9c6;
            border-radius: 4px;
            text-align: center;
            width: fit-content;
        }}
        .column {{
            float: left;
            width: 33.33%;
        }}
    </style>
    <!-- Twitter -->
    <meta name="twitter:card" content="summary_large_image">
    <meta name="twitter:site" content="@EdoardoTosin">
    <meta name="twitter:creator" content="@EdoardoTosin">
    <meta name="twitter:title" content="Automation Tools">
    <meta name="twitter:description" content="Welcome to my personal tech hub! This website is a reflection of my journey in the fascinating world of technology. The blog section is a curated collection of posts demonstrati...">
    <meta property="twitter:image" content="https://edoardotosin.com/assets/img/OGImg.jpg">
</head>
<body>
    <h1>Automation Tools</h1>
    <div class="copy-notification" id="copyNotification">Command copied to clipboard!</div>
    {list_items}
    <script>
        function copyCommand(filename) {{
            const baseUrl = '{base_url}';
            let command;

            if (filename.endsWith('.sh') || filename.endsWith('.bash')) {{
                command = `{curl_linux} "${{baseUrl}}${{filename}}" | bash`;
            }} else if (filename.endsWith('.py') || filename.endsWith('.pyw')) {{
                command = `{curl_linux} "${{baseUrl}}${{filename}}" | python3`;
            }} else if (filename.endsWith('.ps1')) {{
                command = `{curl_win} "${{baseUrl}}${{filename}}" | Invoke-Expression`;
            }} else {{
                alert('Unsupported file type!');
                return;
            }}

            navigator.clipboard.writeText(command).then(() => {{
                const notification = document.getElementById('copyNotification');
                notification.style.display = 'block';
                setTimeout(() => {{
                    notification.style.display = 'none';
                }}, 2000);
            }}, (err) => {{
                alert('Failed to copy!', err);
            }});
        }}
    </script>
</body>
</html>
'''

    with open(os.path.join(scripts_dir, 'index.html'), 'w') as file:
        file.write(html_content)
    print('HTML file generated successfully!')

except Exception as e:
    print(f'Error: {e}')
