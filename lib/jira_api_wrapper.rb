require "jira_api_wrapper/version"

module JiraApiWrapper
  # extend ::Helper

  class << self

    MOCGLOBAL = 'mocglobal'
    ZIPIFYAPPS = 'zipifyapps'
    COSACTION = 'cosaction'
    INSTANCES = [MOCGLOBAL, ZIPIFYAPPS, COSACTION]

    CONFIG = {
      MOCGLOBAL => 'Ym9nZGFuLnNlcmdpaWVua29AbWFzdGVyb2Zjb2RlLmNvbTpnRlBJZmxoZXp0ZlZEc2dMWlFhYTU1OUM=',
      ZIPIFYAPPS => 'b2xlZy5yZXBldHlsb0BtYXN0ZXJvZmNvZGUuY29tOjVQVVhPMUFkTEJZb1VWNDJwTVNmQ0ZBNg==',
      COSACTION => 'ZGltYS5sdWtoYW5pbkBtYXN0ZXJvZmNvZGUuY29tOklPbUg1c3BTa1FRTGUxWGQ4VjMzMjIzNw==',
      # 'romand' => 'Ym9nZGFuLnNlcmdpaWVua29AbWFzdGVyb2Zjb2RlLmNvbTpnRlBJZmxoZXp0ZlZEc2dMWlFhYTU1OUM=',
      # 'trulet' => 'dmlrdG9yaWlhdHltb3NoY2h1a0B0cnVsZXQuY29tOlhWVkFKR2pwZzZmSDdCMkdmY0pDNkRBOQ=='
    }

    ROLES =
      {MOCGLOBAL =>
         {
           'Account Manager' => 10161,
           'Administrators' => 10002,
           'BA' => 10104,
           'Client' => 10110,
           'Designer' => 10162,
           'Developer' => 10102,
           'Developers' => 10236,
           'Lead Developer' => 10105,
           'Project Manager' => 10101,
           'QA' => 10103,
         },
      COSACTION =>
         {
           'Administrators' => 10002,
           'Project Manager' => 10102,
           'Developers' => 10105,
           'Developer Partner' => 10101
         },
      'romand' =>
         {
           'Administrators' => 10002,
           'Developers' => 10102,
         },
      'moctest' =>
         {
           'Administrators' => 10002,
           'Developers' => 10100,
         }
      }

    attr_reader :instance, :all_instances, :api_url, :authorization_type, :current_jwt_user, :token

    def configure(instance: nil, authorization_type: 'Bearer',current_jwt_user: nil, token: nil)
      self.all_instances = instance.present? ? false : true
      unless self.all_instances
        self.instance = instance
        self.api_url = "https://#{instance}/rest/api/2/"
      end
      self.authorization_type = authorization_type
      self.current_jwt_user = current_jwt_user
    end

    def issue_worklogs(issue_key)
      query_url = URI.encode("#{self.api_url}issue/#{issue_key}/worklog")
      request(query_url)
    end

    def worklog_data(issues, from, to, jira_user_names, for_db)
      data = []
      return unless issues.present?
      issues.each do |issue|
        issue.dig('fields', 'worklog', 'worklogs')&.each do |worklog|
          next unless Date.parse(worklog['started']).between?(from, to)
          next unless jira_user_names.include?(worklog.dig('author', 'name'))
          issue_data = {}
          issue_data['project_id'] = issue.dig('fields', 'project', 'id') if for_db
          issue_data['project'] = issue.dig('fields', 'project', 'name')
          issue_data['user_id'] = worklog.dig('author', 'accountId') if for_db
          issue_data['user'] = worklog.dig('author', 'emailAddress')
          issue_data['user_mapped'] = false
          issue_data['project_mapped'] = false
          worklogs_data = []
          worklog_data = {}
          worklog_data['id'] = worklog['id'] if for_db
          worklog_data['date'] = Date.parse(worklog['started'])
          worklog_data['seconds'] = worklog['timeSpentSeconds']
          worklogs_data << worklog_data
          issue_data['worklogs'] = worklogs_data
          data << issue_data
        end
      end

      return data if for_db

      processed_data = []
      group_by = []
      %w(user project).each do |grouping|
        group_by << grouping
        grouped_data = group_data(data, group_by)
        processed_data << detail_data(grouped_data, 'day')
      end
      processed_data.flatten.sort_by {|hash| hash['user']}
    end

    def detail_data(grouped_data, detail_by)
      grouped_data.each {|hash| hash[detail_by] = hash['worklogs'].group_by {|b| b["date"].to_date.strftime("%d.%m.%y")}
                                                    .collect {|key, value| {"date" => key, "seconds" => value.sum {|d| d["seconds"].to_i}}}
                                                    .sort_by {|hash| hash['date'].split('.').reverse}}
      grouped_data.each {|hash| hash['total_time'] = hash['worklogs'].map {|s| s['seconds']}.reduce(0, :+)}
    end

    def api_url
      "https://#{self.resource}.atlassian.net/rest/api/2/"
    end

    def projects(opts = {})
      query_url = 'project'
      query_url += "/#{opts['project_id']}" if opts['project_id'].present?
      response = api_request(query_url)
      if response.is_a?(Array)
        response.collect {|h| ["#{h['name']} - #{h['key']}", h['id']]}
      else
        [["#{response['name']} - #{response['key']}", response['id']]]
      end
    end

    def project_type(project_id)
      query_url = "project/#{project_id}"
      response = api_request(query_url)
      response['style']
    end

    def next_gen_project_roles(project_id)
      roles = {}
      query_url = "project/#{project_id}/role"
      response = api_request(query_url)
      response.each do |el|
        roles['Administrator'] = el[1].split('/').last if el[0] == 'Administrator'
        roles['Member'] = el[1].split('/').last if el[0] == 'Member'
      end
      roles
    end

    def user_role_actors(project_id)
      user_role_actors = []
      project_type = project_type(project_id)
      if project_type == 'next-gen'
        roles = next_gen_project_roles(project_id)
      else
        roles = ROLES[api_base_url.gsub('https://', '')].select {|key, val| key != 'Client'}
      end
      roles.each do |role|
        query_url = "project/#{project_id}/role/#{role[1]}"
        response = api_request(query_url)
        if response['actors']
          users = response.parsed_response['actors'].collect {|h| [h['displayName'], h.dig('actorUser', 'accountId')]}.select {|k, v| v.present?}
        else
          users = []
        end
        user_role_actors << {'role' => role[0], 'actors' => users}
      end
      user_role_actors
    end

    def user_is_in_group?(account_id, group)
      query_url = "user/?accountId=#{account_id}&expand=groups"
      response = api_request(query_url)
      group = Array(group) unless group.is_a?(Array)
      (response.dig('groups', 'items')&.pluck('name') & group).present?
    end

    def user_has_role?(project_id, role)
      project_type = project_type(project_id)
      if project_type == 'next-gen'
        role_id = next_gen_project_roles(project_id)[role]
      else
        role_id = ROLES[api_base_url.gsub('https://', '')][role]
      end
      if role_id.present?
        query_url = "project/#{project_id}/role/#{role_id}"
        response = api_request(query_url)
        if response['actors']
          actors = response.parsed_response['actors'].collect {|h| [h['displayName'], h.dig('actorUser', 'accountId')]}.select {|k, v| v.present?}
          actors.select {|key, val| val == current_jwt_user.account_id}.present?
        else
          false
        end
      else
        false
      end
    end

    def issue_types
      query_url = 'issuetype'
      response = api_request(query_url)
      response.collect {|h| [h['name']]}.uniq
    end

    def statuses
      query_url = 'status'
      response = api_request(query_url)
      response.collect {|h| [h['name'], h['id']]}
    end

    def projects_time_spent(id=nil)
      query_url = id ? "search?fields=worklog&jql=project=#{id}" : "search?fields=project,worklog"
      issues = paged_data(query_url)
      issues.map do |issue|
        if issue.dig('fields', 'worklog', 'worklogs').count == 20
          worklog_response = issue_worklog(issue['key'])
          issue['fields']['worklog'] = worklog_response
        end
      end
      if id
        issues&.map {|h| h['fields']['worklog']['worklogs']&.map {|_h| _h['timeSpentSeconds']}}&.flatten&.inject(:+).to_f
      else
        data = issues&.map {|h| {'project_jira_id' => h['fields']['project']['id'], 'seconds' => h['fields']['worklog']['worklogs']&.map {|_h| _h['timeSpentSeconds']}&.flatten&.inject(:+)}}
        group_data(data, ['project_jira_id'], summing_fields=['seconds'])
      end
    end

    def issue(key)
      query_url = "issue/#{key}"
      api_request(query_url)
    end

    def issue_worklog(issue_key)
      query_url = "issue/#{issue_key}/worklog"
      api_request(query_url)
    end

    def paged_data(query_url)
      maxResults = 100
      query_url += "&maxResults=#{maxResults}"
      issue_quantity = maxResults
      startAt = 0
      issues = []
      while issue_quantity == maxResults do
        response = api_request(query_url+"&startAt=#{startAt}")
        if response['issues'].present?
          issues += response['issues']
          issue_quantity = response['issues'].count
          startAt += maxResults
        else
          issue_quantity = 0
        end
      end
      issues
    end

    def paged_data(query_url)
      maxResults = 100
      query_url += "&maxResults=#{maxResults}"
      issue_quantity = maxResults
      startAt = 0
      issues = []
      while issue_quantity == maxResults do
        response = request(query_url + "&startAt=#{startAt}")
        if response['issues'].present?
          issues += response['issues']
          issue_quantity = response['issues'].count
          startAt += maxResults
        else
          issue_quantity = 0
        end
      end

      if @detailing == 'worklog'
        issues.each do |issue|
          if issue.dig('fields', 'worklog', 'worklogs').count == 20
            worklog_response = issue_worklogs(issue['key'])
            issue['fields']['worklog'] = worklog_response
          end
        end
      end

      issues
    end

    def data(users, from, to, detailing = 'project', for_db = false)
      if users.present?
        if users.kind_of?(Array)
          jira_user_names = users.map {|user| user.moc_email&.split(/@/)&.first}&.reject {|name| name.blank?}.join(',')
        else
          jira_user_names = users.moc_email&.split(/@/)&.first
        end
      end
      @detailing = detailing

      if self.all_resources
        data = []
        CONFIG.each do |resource, token|
          self.resource = resource
          query_url = URI.encode("#{self.api_url}search?fields=project#{detailing == 'issue' ? ',issuetype,summary,' : ''}#{detailing == 'worklog' ? ',worklog' : ''}" +
                                   "&jql=worklogDate>='#{from.strftime('%Y/%m/%d')}' AND worklogDate <= '#{to.strftime('%Y/%m/%d')}'")
          query_url += "AND worklogAuthor in (#{jira_user_names})" if users.present?
          self.token = token
          data += paged_data(query_url)
        end
      else
        query_url = URI.encode("#{self.api_url}search?fields=project#{detailing == 'issue' ? ',issuetype,summary,' : ''}#{detailing == 'worklog' ? ',worklog' : ''}" +
                                 "&jql=worklogDate>='#{from.strftime('%Y/%m/%d')}' AND worklogDate <= '#{to.strftime('%Y/%m/%d')}'")
        query_url += "AND worklogAuthor in (#{jira_user_names})" if users.present?
        self.token = CONFIG[self.resource]
        data = paged_data(query_url)
      end

      case detailing
        when 'project'
          # projects
          data.map {|issue| issue.dig('fields', 'project', 'name')}.uniq
            .reject {|project| project.downcase.include?('moc_')}
        when 'issue'
          # projects and issues
          data.select {|issue| issue.dig('fields', 'summary').downcase.exclude?('meeting')}
            .map {|issue| {'project' => issue.dig('fields', 'project', 'name'), 'issue_type' => issue.dig('fields', 'issuetype', 'name'), 'issue' => issue.dig('fields', 'summary')}}
            .reject {|hash| hash['project'].downcase.include?('moc_')}
            .group_by {|e| e['project']}
        when 'worklog'
          # users, projects and hours
          worklog_data(data, from, to, jira_user_names, for_db)
      end
    end



    def data(opts)
      query_url = create_url(opts)
      paged_data(query_url)
    end

    def create_url(opts)
      query_url = URI.encode("search?fields=project,summary,issuetype,status,comment,customfield_10008,parent,components,worklog&jql=worklogDate >= #{opts['from']} AND worklogDate <= #{opts['to']}")
      if opts.key?('projects')
        query_url += " AND project in (#{opts['projects'].map {|el| "'#{el}'"}.join(',')})"
      end
      if opts.key?('issue_types')
        query_url += URI.encode(" AND issuetype in (#{opts['issue_types'].map {|el| "'#{el}'"}.join(',')})")
      end
      if opts.key?('users')
        query_url += URI.encode(" AND worklogAuthor in (#{opts['users'].map {|el| "'#{el}'"}.join(',')})")
      end
      if opts.key?('statuses')
        query_url += URI.encode(" AND status in (#{opts['statuses'].map {|el| "'#{el}'"}.join(',')})")
      end
      query_url
    end

    def api_request(query_url)
      url = api_url + query_url
      begin
        if authorization_type == 'Bearer'
          HTTParty.get(url, {
            headers: {'Content-Type' => 'application/json', 'Authorization' => "Bearer " + current_jwt_user.oauth_access_token}
          }).parsed_response
        else
          HTTParty.get(url, {
            headers: {'Content-Type' => 'application/json', 'Authorization' => "Basic Ym9nZGFuLnNlcmdpaWVua29AbWFzdGVyb2Zjb2RlLmNvbTpnRlBJZmxoZXp0ZlZEc2dMWlFhYTU1OUM="}
          }).parsed_response
        end
      rescue SocketError, Errno::ECONNREFUSED, Timeout::Error, HTTParty::Error, OpenSSL::SSL::SSLError  => e
        Rails.logger.info "Error: at #{Time.now} - #{e.message}"
        {}
      end
    end

    # def request(query_url)
    #   begin
    #     HTTParty.get(query_url, {
    #       headers: {'Content-Type' => 'application/json', 'Authorization' => "Basic #{CONFIG[self.resource]}"}
    #     }).parsed_response
    #   rescue SocketError, Errno::ECONNREFUSED, Timeout::Error, HTTParty::Error, OpenSSL::SSL::SSLError  => e
    #     Rails.logger.info "Error: at #{Time.now} - #{e.message}"
    #     {}
    #   end
    # end



    def test
      puts 'Success!'
    end

    private

    def group_data(data, grouping_fields, summing_fields=['worklogs'])
      grouped_data = data.group_by {|hash| hash.values_at(*grouping_fields).join ":"}.values.map do |grouped|
        grouped.inject do |merged, n|
          merged.merge(n) do |key, v1, v2|
            if key.in?(grouping_fields)
              v1
            elsif key.in?(summing_fields)
              if v1.respond_to?(:to_i) && v2.respond_to?(:to_i)
                v1.to_i + v2.to_i
              else
                v1 + v2
              end
            else
              ''
            end
          end
        end
      end

      grouped_data.sort_by {|hash| hash.values_at(*grouping_fields).join ":"}
    end

    # def group_data(data, grouping_fields, summing_fields=['worklogs'])
    #   grouped_data = data.group_by {|hash| hash.values_at(*grouping_fields).join ":"}.values.map do |grouped|
    #     grouped.inject do |merged, n|
    #       merged.merge(n) do |key, v1, v2|
    #         if grouping_fields.include?(key)
    #           v1
    #         elsif summing_fields.include?(key)
    #           if v1.respond_to?(:to_i) && v2.respond_to?(:to_i)
    #             v1.to_i + v2.to_i
    #           else
    #             v1 + v2
    #           end
    #         end
    #       end
    #     end
    #   end
    #
    #   grouped_data.sort_by {|hash| hash.values_at(*grouping_fields).join ":"}
    # end



  end
end
