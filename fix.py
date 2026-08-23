import re
with open("workloads/voltron-demo/pipelines/sdv_voltron_builder/helm/templates/workflow/workflowtemplates.yaml", "r") as f:
    text = f.read()

text = text.replace(
'''        artifacts:
          - name: source
            git:
              repo: "https://github.com/tudormot/horizon-sdv.git"
              depth: 1''',
'''        artifacts:
          - name: source
            path: /src
            git:
              repo: "https://github.com/tudormot/horizon-sdv.git"
              depth: 1'''
)
with open("workloads/voltron-demo/pipelines/sdv_voltron_builder/helm/templates/workflow/workflowtemplates.yaml", "w") as f:
    f.write(text)
